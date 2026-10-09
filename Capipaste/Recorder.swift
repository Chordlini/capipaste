import AVFoundation
import CoreAudio

struct AudioInput: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isDefault: Bool
    /// AirPods and other headsets: opening their mic drops playback to call quality.
    var isBluetooth = false
    var isBuiltIn = false

    /// Every Core Audio device that has input channels.
    static func all() -> [AudioInput] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let defaultID: AudioDeviceID = property(system, kAudioHardwarePropertyDefaultInputDevice) ?? 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            // Voice processing and CoreAudio make hidden aggregate devices of their own; they aren't mics you pick.
            let hidden: UInt32 = property(id, kAudioDevicePropertyIsHidden) ?? 0
            guard hidden == 0, inputChannels(id) > 0,
                  let uid: CFString = property(id, kAudioDevicePropertyDeviceUID),
                  let name: CFString = property(id, kAudioObjectPropertyName)
            else { return nil }
            let label = name as String
            if label.hasPrefix("CADefaultDeviceAggregate") || label.hasPrefix("VPAUAggregateAudioDevice") { return nil }
            let transport: UInt32 = property(id, kAudioDevicePropertyTransportType) ?? 0
            // While voice processing runs, the built-in speakers grow an echo-reference input with no terminal type
            // (0); the real built-in mic reports one (0x201, the USB "microphone" code, not CoreAudio's 'micr').
            if transport == kAudioDeviceTransportTypeBuiltIn, inputTerminals(id).allSatisfy({ $0 == 0 }) {
                return nil
            }
            return AudioInput(id: id, uid: uid as String, name: name as String, isDefault: id == defaultID,
                              isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                              isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn)
        }
    }

    /// Your pick if it's plugged in; else the default, unless that's a headset and a built-in mic exists.
    static func choose(from mics: [AudioInput], picked uid: String?, avoidBluetooth: Bool) -> AudioInput? {
        if let picked = mics.first(where: { $0.uid == uid }) { return picked }
        let standard = mics.first { $0.isDefault }
        if avoidBluetooth, standard?.isBluetooth == true, let builtIn = mics.first(where: \.isBuiltIn) { return builtIn }
        return standard
    }

    /// Calls `changed` (on the main queue) when this system property changes: the device list or the default input.
    static func watch(_ selector: AudioObjectPropertySelector, _ changed: @escaping @Sendable () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in changed() }
    }

    private static func inputTerminals(_ id: AudioDeviceID) -> [UInt32] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &streams) == noErr else { return [] }
        return streams.map { property($0, kAudioStreamPropertyTerminalType) ?? 0 }
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func property<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.move()
    }
}

/// Taps the chosen microphone and hands out 16 kHz mono samples plus a 0...1 level.
/// Every engine call runs on one serial queue: a stop that lands while a start is still opening the
/// device waits its turn instead of racing it, and a device that hangs blocks only this queue.
final class Recorder: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "capipaste.recorder", qos: .userInitiated)
    // Queue-confined from here down.
    private static var warm: (engine: AVAudioEngine, device: AudioDeviceID?)?
    /// Whoever has the tap on the warm engine; a second recorder takes it over instead of double-tapping.
    private static weak var owner: Recorder?
    private var engine: AVAudioEngine?
    private var mic: DeviceInput?
    private var observer: NSObjectProtocol?
    private var device: AudioInput?
    private var onAudio: (@Sendable ([Float], Float) -> Void)?
    private var reopens = 0

    /// Turning on voice processing costs ~0.7 s, so do it off the hotkey path. Doesn't open the mic.
    static func prewarm() { queue.async { if owner == nil { _ = try? voiceEngine() } } }

    /// The default input or output changed (`force` after sleep): the ready engine may point at a stale device
    /// or rate, or a headset just arrived. Only a real change rebuilds it: voice processing adds a hidden device
    /// of its own, and rebuilding on every device-list change looped, starving the mic and stuttering playback.
    static func invalidate(force: Bool = false) {
        queue.async {
            guard owner == nil else { return }
            if force { drop() }
            _ = try? voiceEngine()
        }
    }

    /// A Bluetooth headset as default input or output. Voice processing opens the default mic and uses the
    /// output for echo cancelling, which holds the headset in call mode (mono, muffled playback) the whole
    /// time the ready engine exists, even when you record from the built-in mic. So no noise suppression then.
    private static func bluetoothInvolved() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        return [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice].contains { selector in
            guard let id: AudioDeviceID = AudioInput.property(system, selector) else { return false }
            let transport: UInt32 = AudioInput.property(id, kAudioDevicePropertyTransportType) ?? 0
            return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        }
    }

    /// Lets go of the ready engine and the devices voice processing holds open.
    private static func drop() {
        guard let engine = warm?.engine else { return }
        warm = nil
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
    }

    // ponytail: one cached engine, rebuilt when the default input changes
    private static func voiceEngine() throws -> AVAudioEngine {
        guard !bluetoothInvolved() else {
            if warm != nil { trace("recorder: Bluetooth headset in use, released voice processing") }
            drop()
            throw RecorderError.bluetooth
        }
        let device = defaultInputID()
        if let warm, warm.device == device { return warm.engine }
        drop()
        let began = Date()
        defer { trace("recorder: voice processing ready in \(Int(Date().timeIntervalSince(began) * 1000)) ms") }
        let engine = AVAudioEngine()
        // Apple's voice processing: noise suppression + echo cancel. Must be set before reading the format.
        try engine.inputNode.setVoiceProcessingEnabled(true)
        if #available(macOS 14.0, *) {
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        warm = (engine, device)
        return engine
    }

    private static func defaultInputID() -> AudioDeviceID? {
        AudioInput.property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
    }

    func start(device: AudioInput?, onAudio: @escaping @Sendable ([Float], Float) -> Void) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let queued = Date()
            Self.queue.async {
                let waited = Int(Date().timeIntervalSince(queued) * 1000)
                if waited > 100 { trace("recorder: start waited \(waited) ms for the audio queue") }
                self.device = device
                self.onAudio = onAudio
                self.reopens = 0
                do { try self.open(); done.resume() } catch { done.resume(throwing: error) }
            }
        }
    }

    func stop() {
        Self.queue.async {
            self.close()
            self.onAudio = nil
        }
    }

    private func open() throws {
        close()
        // Voice processing (noise suppression) only runs on the system default input: pointing it at another
        // device fails to initialize (-10875) and can hang the next start. Other mics record raw.
        let suppress = (device == nil || device?.id == Self.defaultInputID()) && !Self.bluetoothInvolved()
        do {
            try open(suppress: suppress)
        } catch where suppress {
            // The ready engine may be stale (sleep, a sample-rate change): build it fresh once, then go raw.
            trace("recorder: voice processing start failed (\(error)), rebuilding")
            close()
            Self.drop()
            do {
                try open(suppress: true)
            } catch {
                trace("recorder: voice processing failed again (\(error)), recording raw")
                close()
                Self.drop()
                try open(suppress: false)
            }
        }
    }

    private func open(suppress: Bool) throws {
        guard let onAudio else { return } // stopped before it got here
        if !suppress, let device {
            // A picked mic opens on its own. AVAudioEngine's input node opens the system default input first,
            // and when that's a Bluetooth headset it flips it to call mode before the switch to your mic lands.
            // The id can go stale when a device reconnects; the uid doesn't.
            let id = AudioInput.all().first(where: { $0.uid == device.uid })?.id ?? device.id
            let began = Date()
            let mic = try DeviceInput(device: id)
            self.mic = mic // set before start so close() can clean up a failed start
            try mic.start(Self.pipe(from: mic.format, to: onAudio) { [weak self, weak mic] in
                Self.queue.async { self?.reopen(mic, because: "the mic is delivering only zeros") }
            })
            trace("recorder: \(device.name) opened in \(Int(Date().timeIntervalSince(began) * 1000)) ms (raw, \(Int(mic.format.sampleRate)) Hz)")
            return
        }
        let engine: AVAudioEngine
        if suppress {
            engine = try Self.voiceEngine()
            if let other = Self.owner, other !== self {
                trace("recorder: taking the mic over from another take")
                other.close()
            }
            Self.owner = self
        } else {
            engine = AVAudioEngine() // no mic picked: the system default, fresh per session
        }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        let deliver = try Self.pipe(from: inFormat, to: onAudio) { [weak self, weak engine] in
            Self.queue.async { self?.reopen(engine, because: "the mic is delivering only zeros") }
        }
        input.removeTap(onBus: 0) // never two taps on one bus: AVAudioEngine throws an exception for that
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buffer, _ in deliver(buffer) }
        self.engine = engine // set before start so close() can clean up a failed start
        // Unplugged AirPods, a new default input or a sample-rate change stop the engine: open it again.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [weak self, weak engine] _ in
            // Voice processing posts one of these as it settles, with the engine still running: only a stopped
            // engine (a real device change) needs reopening, otherwise every take would get gaps.
            Self.queue.async {
                guard let engine, !engine.isRunning else { return }
                self?.reopen(engine, because: "the audio device changed")
            }
        }
        let began = Date()
        engine.prepare()
        try engine.start()
        trace("recorder: engine started in \(Int(Date().timeIntervalSince(began) * 1000)) ms (\(suppress ? "noise suppression" : "raw"), \(Int(inFormat.sampleRate)) Hz × \(inFormat.channelCount))")
    }

    /// Turns the device's buffers into 16 kHz mono samples plus a level; `stuck` fires once on ~1 s of zeros.
    private static func pipe(from inFormat: AVAudioFormat, to onAudio: @escaping @Sendable ([Float], Float) -> Void,
                             stuck: @escaping () -> Void) throws -> (AVAudioPCMBuffer) -> Void {
        guard inFormat.sampleRate > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw RecorderError.noInput }
        converter.channelMap = [0] // voice processing hands back 9 channels; without this the mono downmix is silent
        let silence = SilenceWatch()
        var hum = HumFilter()
        return { buffer in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / inFormat.sampleRate) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard let data = out.floatChannelData?[0], out.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
            let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
            if silence.stuck(rms) { stuck() }
            onAudio(samples, Self.level(rms: hum.rms(samples)))
        }
    }

    /// The same take on a freshly opened device, a couple of times at most.
    private func reopen(_ stale: AnyObject?, because reason: String) {
        guard let stale, stale === (engine ?? mic), onAudio != nil, reopens < 3 else { return }
        reopens += 1
        trace("recorder: reopening, \(reason)")
        if Self.warm?.engine === stale { Self.drop() }
        do { try open() } catch { trace("recorder: reopen failed \(error)") }
    }

    private func close() {
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        mic?.stop()
        mic = nil
        if Self.owner === self { Self.owner = nil }
    }

    /// dB window -60...0 so speech sits mid-meter instead of pinned.
    // ponytail: fixed window, expose a gain knob if quiet mics look flat
    static func level(rms: Float) -> Float {
        guard rms.isFinite else { return 0 }
        return min(max((20 * log10(max(rms, 1e-6)) + 60) / 60, 0), 1)
    }

    enum RecorderError: Error { case noInput, deviceRefused(OSStatus), bluetooth }
}

/// The meter's level without mains hum. With no voice processing (a picked mic, a Bluetooth headset on) the
/// built-in mic carries ~120–180 Hz hum around -24 dB, which kept the meter half full and every buffer "loud"
/// in silence. A 300 Hz high-pass drops that floor to about -38 dB; speech sits above it. Samples aren't touched.
struct HumFilter {
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    // RBJ biquad high-pass, 300 Hz, Q 0.707, at 16 kHz.
    private static let (b0, b1, b2, a1, a2): (Float, Float, Float, Float, Float) = {
        let w = 2 * Float.pi * 300 / 16_000, alpha = sin(w) / (2 * 0.707), c = cos(w), a0 = 1 + alpha
        return ((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0)
    }()

    mutating func rms(_ samples: [Float]) -> Float {
        var sum: Float = 0
        for x in samples {
            let y = Self.b0 * x + Self.b1 * x1 + Self.b2 * x2 - Self.a1 * y1 - Self.a2 * y2
            (x2, x1, y2, y1) = (x1, x, y1, y)
            sum += y * y
        }
        return samples.isEmpty ? 0 : (sum / Float(samples.count)).squareRoot()
    }
}

/// A device that opens fine but hands over nothing but exact zeros (the voice-processing downmix bug,
/// a muted aggregate). Real rooms are never digitally silent, so ~1 s of zeros from the start means stuck.
final class SilenceWatch: @unchecked Sendable {
    private var zeros = 0
    private var heard = false
    private var reported = false

    func stuck(_ rms: Float) -> Bool {
        guard !heard, !reported else { return false }
        if rms > 0 { heard = true; return false }
        zeros += 1
        if zeros >= 16 { reported = true }
        return reported
    }
}

/// One specific mic through a bare HAL unit: only that device opens, the system default is never touched.
final class DeviceInput: @unchecked Sendable {
    let format: AVAudioFormat
    private var unit: AudioUnit?
    private var deliver: ((AVAudioPCMBuffer) -> Void)?
    // ponytail: one buffer reused per callback; HAL slices are ≤ 4096 frames by default
    private let buffer: AVAudioPCMBuffer
    /// The HAL hands over ~10 ms slices; the meter moves one dot per delivery, so they go out ~100 ms at a time
    /// like AVAudioEngine's.
    private let chunk: AVAudioPCMBuffer

    init(device: AudioDeviceID) throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        var made: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description),
              AudioComponentInstanceNew(component, &made) == noErr, let unit = made
        else { throw Recorder.RecorderError.noInput }
        self.unit = unit
        func set<T>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ bus: AudioUnitElement, _ value: T) throws {
            var value = value
            let status = AudioUnitSetProperty(unit, property, scope, bus, &value, UInt32(MemoryLayout<T>.size))
            guard status == noErr else { AudioComponentInstanceDispose(unit); throw Recorder.RecorderError.deviceRefused(status) }
        }
        try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1))  // bus 1 is the mic
        try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0)) // no speaker side
        try set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device)
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        // The HAL unit can't resample: take the device's own rate, as one float channel.
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size) == noErr,
              hardware.mSampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.mSampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(hardware.mSampleRate / 10) + 8192)
        else { AudioComponentInstanceDispose(unit); throw Recorder.RecorderError.noInput }
        self.format = format
        self.buffer = buffer
        self.chunk = chunk
        try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, format.streamDescription.pointee)
    }

    func start(_ deliver: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard let unit else { throw Recorder.RecorderError.noInput }
        self.deliver = deliver
        var callback = AURenderCallbackStruct(inputProc: { context, flags, time, bus, frames, _ in
            Unmanaged<DeviceInput>.fromOpaque(context).takeUnretainedValue().pull(flags, time, bus, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        var status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                          &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        if status == noErr { status = AudioUnitInitialize(unit) }
        if status == noErr { status = AudioOutputUnitStart(unit) }
        guard status == noErr else { throw Recorder.RecorderError.deviceRefused(status) }
    }

    private func pull(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>,
                      _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let unit, frames <= buffer.frameCapacity else { return noErr }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, time, bus, frames, buffer.mutableAudioBufferList)
        guard status == noErr, let from = buffer.floatChannelData?[0], let to = chunk.floatChannelData?[0] else { return status }
        (to + Int(chunk.frameLength)).update(from: from, count: Int(frames))
        chunk.frameLength += frames
        if Double(chunk.frameLength) >= format.sampleRate / 10 {
            deliver?(chunk)
            chunk.frameLength = 0
        }
        return status
    }

    /// Stops and frees the unit; the callback can't fire after this returns.
    func stop() {
        guard let unit else { return }
        self.unit = nil
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    deinit { stop() }
}
