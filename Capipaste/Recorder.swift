import AVFoundation
import CoreAudio

struct AudioInput: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isDefault: Bool

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
            guard inputChannels(id) > 0,
                  let uid: CFString = property(id, kAudioDevicePropertyDeviceUID),
                  let name: CFString = property(id, kAudioObjectPropertyName)
            else { return nil }
            return AudioInput(id: id, uid: uid as String, name: name as String, isDefault: id == defaultID)
        }
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
final class Recorder: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private static let lock = NSLock()
    private static var warm: (engine: AVAudioEngine, device: AudioDeviceID?)?

    /// Turning on voice processing costs ~0.7 s, so do it off the hotkey path. Doesn't open the mic.
    static func prewarm() { lock.withLock { _ = try? voiceEngine() } }

    // ponytail: one cached engine, rebuilt when the default input changes
    private static func voiceEngine() throws -> AVAudioEngine {
        let device = defaultInputID()
        if let warm, warm.device == device { return warm.engine }
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

    func start(device: AudioInput?, onAudio: @escaping @Sendable ([Float], Float) -> Void) throws {
        // Voice processing (noise suppression) only runs on the system default input: pointing it at another
        // device fails to initialize (-10875) and can hang the next start. Other mics record raw.
        let suppress = device == nil || device?.id == Self.defaultInputID()
        do {
            try start(device: device, suppress: suppress, onAudio: onAudio)
        } catch where suppress {
            trace("recorder: voice processing start failed (\(error)), retrying raw")
            stop()
            Self.lock.withLock { Self.warm = nil }
            try start(device: device, suppress: false, onAudio: onAudio)
        }
    }

    private func start(device: AudioInput?, suppress: Bool, onAudio: @escaping @Sendable ([Float], Float) -> Void) throws {
        // Raw: fresh engine per session so device switches always apply. Suppressed: the prewarmed one.
        let engine = suppress ? try Self.lock.withLock { try Self.voiceEngine() } : AVAudioEngine()
        let input = engine.inputNode
        if !suppress, var id = device?.id, let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw RecorderError.noInput }
        converter.channelMap = [0] // voice processing hands back 9 channels; without this the mono downmix is silent

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buffer, _ in
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
            // ponytail: fixed dB window (-60...0) so speech sits mid-meter instead of pinned; gain knob if quiet mics look flat
            let level = min(max((20 * log10(max(rms, 1e-6)) + 60) / 60, 0), 1)
            onAudio(samples, level)
        }
        self.engine = engine // set before start so stop() can clean up a failed start
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    enum RecorderError: Error { case noInput }
}
