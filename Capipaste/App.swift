import AVFoundation
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let capture = Self("capture", default: .init(.s, modifiers: [.command, .shift]))
    static let dictate = Self("dictate")  // optional shortcut; hold-to-talk is the main trigger
    static let clip = Self("clip", default: .init(.s, modifiers: [.command, .control]))
    static let pasteLast = Self("pasteLast", default: .init(.v, modifiers: [.command, .control]))
}

@main
struct CapipasteApp: App {
    @State private var app = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(app)
                .environment(app.stt)
                .environment(app.permissions)
        } label: {
            Image(nsImage: MenuGlyph.image)
        }
        .menuBarExtraStyle(.window)

    }
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let stt = STT()
    let permissions = Permissions()
    let updater = Updater()
    let tidy = Tidy()
    private(set) var pushToTalk: PushToTalk!
    fileprivate(set) var dictation: DictationBar?
    var mics: [AudioInput] = []
    var micUID: String? = UserDefaults.standard.string(forKey: "micUID") {
        didSet { UserDefaults.standard.set(micUID, forKey: "micUID") }
    }
    private var card: CaptureCard?

    nonisolated static let capturesFolder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Capipaste", isDirectory: true)

    private init() {
        KeyboardShortcuts.onKeyUp(for: .capture) { [weak self] in self?.capture() }
        KeyboardShortcuts.onKeyUp(for: .clip) { [weak self] in self?.recordClip() }
        KeyboardShortcuts.onKeyUp(for: .pasteLast) { [weak self] in self?.pasteLast() }
        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in self?.startDictation() }
        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in self?.dictation?.finish() }
        refreshMics()
        AudioInput.watch(kAudioHardwarePropertyDevices) { Task { @MainActor in AppModel.shared.refreshMics() } }
        AudioInput.watch(kAudioHardwarePropertyDefaultInputDevice) {
            Recorder.invalidate()
            Task { @MainActor in AppModel.shared.refreshMics() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            flushLog()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Recorder.invalidate(force: true)
        }
        permissions.onAccessibilityGranted = { [weak self] in
            trace("permissions: accessibility granted, arming hold-to-talk")
            self?.pushToTalk?.restart()
        }
        permissions.refresh()
        watchForAccessibility()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.permissions.refresh() }
        }
        pushToTalk = PushToTalk(
            onStart: { [weak self] in self?.startDictation() },
            onAbort: { [weak self] in self?.dictation?.cancel() },
            onStop: { [weak self] in self?.dictation?.finish() })
        Task { await stt.warmUp() }
        Task.detached(priority: .utility) { Recordings.prune() }
        if updater.checkOnLaunch { Task { await updater.check() } }
        showSettingsOnFirstRun()
        openDemoIfRequested()
        if hookArguments.contains("-autocapture") { capture() }
        if hookArguments.contains("-autoclip") { recordClip() }
        transcribeFileIfRequested()
        menuShotIfRequested()
        dictateIfRequested()
        settingsCheckIfRequested()
        updateCheckIfRequested()
        tidyIfRequested()
        if hookArguments.contains("-recopy"), let last = History.recent(1).first {
            // testing: put the last capture back on the clipboard and quit
            History.copy(last, textOnly: false)
            trace("history: recopied \(last.note.lastPathComponent), images=\(last.images.count), title=\(last.title)")
            NSApp.terminate(nil)
        }
    }

    /// CoreAudio can stall on a sleepy Bluetooth device, so the list is read off the main thread.
    func refreshMics() {
        Task.detached(priority: .userInitiated) {
            let found = AudioInput.all()
            Recorder.prewarm()
            await MainActor.run {
                self.mics = found
                if let uid = self.micUID, !found.contains(where: { $0.uid == uid }) { self.micUID = nil }
            }
        }
    }

    /// With no mic picked, the system default, except that a Bluetooth headset gives way to the built-in mic
    /// (Settings › Speech) so your music doesn't drop to call quality.
    var selectedMic: AudioInput? {
        AudioInput.choose(from: mics, picked: micUID,
                          avoidBluetooth: UserDefaults.standard.object(forKey: "avoidBluetoothMic") as? Bool ?? true)
    }

    func capture() {
        let source = NSWorkspace.shared.frontmostApplication
        trace("capture: hotkey, card open=\(card != nil), screen access=\(CGPreflightScreenCaptureAccess())")
        if let card {
            // Another region for the same note.
            card.hide()
            Task {
                let url = await Capture.region()
                if let url, let image = NSImage(contentsOf: url) {
                    try? FileManager.default.removeItem(at: url)
                    card.add(image)
                } else {
                    card.focus()
                }
            }
            return
        }
        guard hasScreenAccess() else { return }
        let context = Task { await CaptureContext.read(from: source) }
        Task {
            let url = await Capture.region()
            trace("capture: region file=\(url?.path ?? "none")")
            guard let url, let image = NSImage(contentsOf: url) else { return }
            try? FileManager.default.removeItem(at: url)
            await open(image, returnTo: source, context: await context.value)
        }
    }

    /// Records a short clip of a region, then opens the card on its first frame.
    func recordClip() {
        let source = NSWorkspace.shared.frontmostApplication
        guard card == nil else { card?.focus(); return }
        guard hasScreenAccess() else { return }
        let context = Task { await CaptureContext.read(from: source) }
        Task {
            guard let clip = await Clip.record(), let first = clip.frames.first else { return }
            await open(first, returnTo: source, context: await context.value, clip: clip)
        }
    }

    /// Without Screen Recording, screencapture quietly returns just the wallpaper: ask, and show where to
    /// allow it, instead of opening a card on a blank shot.
    private func hasScreenAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        trace("capture: no Screen Recording access")
        CGRequestScreenCaptureAccess() // macOS shows its own prompt the first time
        permissions.refresh()
        openSettings(tab: .permissions)
        return false
    }

    /// Copies the last capture again and pastes it where you are.
    func pasteLast() {
        guard let last = History.recent(1).first else { NSSound.beep(); return }
        History.copy(last, textOnly: Terminals.contains(NSWorkspace.shared.frontmostApplication))
        trace("history: re-pasted \(last.note.lastPathComponent)")
        Output.paste()
    }

    private func open(_ image: NSImage, returnTo source: NSRunningApplication? = nil, context: CaptureContext? = nil,
                      clip: Clip.Recording? = nil) async {
        trace("open: image \(image.size), mic status=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        // One take owns the mic and the speech engine at a time.
        if let card {
            card.add(image) // a second capture (or a clip) that finished while this card was open joins it
            return
        }
        dictation?.cancel()
        card = CaptureCard(image: image, mic: selectedMic, stt: stt, textOnly: Terminals.contains(source), context: context, clip: clip) { [weak self] in
            self?.card = nil
            // Hand focus back so ⌘V lands where the capture started.
            source?.activate()
        }
        trace("open: card created")
    }

    /// `-demo <png>` opens the card on an existing image (testing, README shots).
    private func openDemoIfRequested() {
        let args = hookArguments
        guard let i = args.firstIndex(of: "-demo"), i + 1 < args.count,
              let image = NSImage(contentsOfFile: args[i + 1]) else { return }
        Task { await open(image) }
    }

    /// `-tidy <note>` rewrites one note, logs it and quits (testing). Add `-tidydownload` to fetch the local model first.
    private func tidyIfRequested() {
        let args = hookArguments
        guard let i = args.firstIndex(of: "-tidy"), i + 1 < args.count else { return }
        Task {
            if args.contains("-tidydownload"), !tidy.localReady {
                tidy.downloadLocal()
                while !tidy.localReady, tidy.problem == nil { try? await Task.sleep(for: .milliseconds(500)) }
            }
            trace("tidy test: engine=\(tidy.engine) problem=\(tidy.problem ?? "none")")
            for _ in 0..<2 { // second run is the warm one
                let out = await tidy.rewrite(args[i + 1])
                trace("tidy test: \(out ?? "<nil>")")
            }
            NSApp.terminate(nil)
        }
    }

    /// `-updatecheck` runs one update check and logs the outcome (testing).
    private func updateCheckIfRequested() {
        guard hookArguments.contains("-updatecheck") else { return }
        Task {
            await updater.check()
            trace("updater: status=\(updater.status) current=\(updater.currentVersion) latest=\(updater.release?.version ?? "none")")
            NSApp.terminate(nil)
        }
    }

    /// `-settingscheck` opens Settings and logs the window it made (testing).
    private func settingsCheckIfRequested() {
        guard hookArguments.contains("-settingscheck") else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            openSettings()
            try? await Task.sleep(for: .seconds(2))
            let windows = NSApp.windows.filter(\.isVisible).map { "\($0.title)|\(Int($0.frame.width))x\(Int($0.frame.height))" }
            trace("settings: windows \(windows.joined(separator: ", "))")
            NSApp.terminate(nil)
        }
    }

    /// `-dictate <seconds>` runs one hold-to-talk take without the key (testing).
    private func dictateIfRequested() {
        let args = hookArguments
        guard let i = args.firstIndex(of: "-dictate"), i + 1 < args.count,
              let seconds = Double(args[i + 1]) else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            startDictation()
            try? await Task.sleep(for: .seconds(seconds))
            dictation?.finish()
        }
    }

    /// `-menushot <png>` renders the menu-bar panel to a file (testing).
    private func menuShotIfRequested() {
        let args = hookArguments
        guard let i = args.firstIndex(of: "-menushot") ?? args.firstIndex(of: "-settingsshot"),
              i + 1 < args.count else { return }
        let settings = args.contains("-settingsshot")
        let view = AnyView(
            settings
                ? AnyView(SettingsView().environment(self).environment(stt).environment(permissions).environment(updater))
                : AnyView(MenuView().environment(self).environment(stt).environment(permissions)))
        Task {
            try? await Task.sleep(for: .milliseconds(600)) // let fonts and state settle
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            NSApp.terminate(nil)
        }
    }

    /// `-sttfile <audio>…` runs the active speech model over each file, logs the results and quits (testing).
    /// `-sttmodel <name>` picks the model for this run (downloading it first); your choice is restored after.
    private func transcribeFileIfRequested() {
        let args = hookArguments
        guard let i = args.firstIndex(of: "-sttfile"), i + 1 < args.count else { return }
        let files = args[(i + 1)...].prefix { !$0.hasPrefix("-") }
        Task {
            let chosen = stt.active
            if let m = args.firstIndex(of: "-sttmodel"), m + 1 < args.count, let model = SpeechModel(rawValue: args[m + 1]) {
                if !stt.isReady(model) {
                    stt.download(model)
                    while !stt.isReady(model), stt.problem == nil { try? await Task.sleep(for: .milliseconds(500)) }
                }
                stt.active = model
                await stt.warmUp()
            }
            for path in files { await transcribe(file: path) }
            if stt.active != chosen { stt.active = chosen }
            NSApp.terminate(nil)
        }
    }

    private func transcribe(file path: String) async {
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: input)
            let converter = AVAudioConverter(from: file.processingFormat, to: format)!
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 16)!
            var fed = false
            converter.convert(to: output, error: nil) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true
                status.pointee = .haveData
                return input
            }
            let samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            trace("sttfile: \(samples.count) samples with \(stt.inUse)")
            stt.begin()
            for start in stride(from: 0, to: samples.count, by: 1600) {
                stt.feed(Array(samples[start..<min(start + 1600, samples.count)]))
            }
            let began = Date()
            let text = await stt.finish(expectSpeech: true).text
            trace("sttfile: \(stt.inUse) \((path as NSString).lastPathComponent) finish=\(Int(Date().timeIntervalSince(began) * 1000)) ms result=\(text ?? "nil (failed)") problem=\(stt.problem ?? "none")")
        } catch {
            trace("sttfile: \(error)")
        }
    }

    /// Hold-to-talk: a bar with the live transcript, no screenshot.
    func startDictation() {
        // The card owns the speech session while it's open: right-⌘+Z there must not restart it.
        guard dictation == nil, card == nil else { return }
        let source = NSWorkspace.shared.frontmostApplication
        trace("dictation: start from \(source?.localizedName ?? "unknown")")
        dictation = DictationBar(mic: selectedMic, stt: stt, returnTo: source,
                                 autoPaste: permissions.canDictateHandsFree) { [weak self] in
            self?.dictation = nil
        }
    }

    /// macOS doesn't tell us when Accessibility is granted, so glance at it until it is.
    private func watchForAccessibility() {
        guard permissions.accessibility != .granted else { return }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { return timer.invalidate() }
                self.permissions.refresh()
                if self.permissions.accessibility == .granted { timer.invalidate() }
            }
        }
    }

    /// Called after the permission list is refreshed: pick up a freshly granted Accessibility.
    func permissionsChanged() {
        pushToTalk?.restart()
    }

    func openSettings(tab: SettingsView.Tab = .general) {
        SettingsWindow.shared.show(
            SettingsView(tab: tab)
                .environment(self)
                .environment(stt)
                .environment(permissions)
                .environment(updater))
    }

    private func showSettingsOnFirstRun() {
        let key = "didShowSetup"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            openSettings()
        }
    }

    func openCapturesFolder() {
        try? FileManager.default.createDirectory(at: Self.capturesFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.capturesFolder)
    }
}

enum Capture {
    /// Native macOS region picker: drag to size, Space for window mode, Esc to cancel.
    static func region() async -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capipaste-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // `-autocapture x,y,w,h` grabs a fixed rect instead of the interactive picker (testing).
        let args = hookArguments
        if let i = args.firstIndex(of: "-autocapture"), i + 1 < args.count {
            process.arguments = ["-x", "-R", args[i + 1], url.path]
        } else {
            process.arguments = ["-i", "-x", url.path]
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in done.resume() }
            do { try process.run() } catch { done.resume() }
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

enum MenuGlyph {
    /// Capture corners with a pair of horns, drawn as a template image.
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            let corners = NSBezierPath()
            corners.lineWidth = 1.6
            corners.lineCapStyle = .round
            for (a, b, c) in [((2, 6), (2, 2), (6, 2)), ((12, 2), (16, 2), (16, 6)),
                              ((16, 12), (16, 16), (12, 16)), ((6, 16), (2, 16), (2, 12))] {
                corners.move(to: NSPoint(x: a.0, y: a.1))
                corners.line(to: NSPoint(x: b.0, y: b.1))
                corners.line(to: NSPoint(x: c.0, y: c.1))
            }
            corners.stroke()
            let horns = NSBezierPath()
            horns.lineWidth = 1.6
            horns.lineCapStyle = .round
            horns.move(to: NSPoint(x: 6.5, y: 12))
            horns.curve(to: NSPoint(x: 11.5, y: 12), controlPoint1: NSPoint(x: 6.5, y: 5.5),
                        controlPoint2: NSPoint(x: 11.5, y: 5.5))
            horns.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// Appends a line to ~/Library/Logs/Capipaste.log (capture-flow breadcrumbs). One writer at a time, from
/// any thread; past 2 MB the log moves to Capipaste.old.log so it never grows without end.
func trace(_ message: String) {
    let line = "\(Date().formatted(.iso8601)) \(message)\n"
    Log.queue.async {
        let manager = FileManager.default
        if let size = (try? manager.attributesOfItem(atPath: Log.url.path))?[.size] as? Int, size > 2_000_000 {
            let old = Log.url.deletingLastPathComponent().appendingPathComponent("Capipaste.old.log")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: Log.url, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: Log.url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: Log.url)
        }
    }
}

/// Waits for queued log lines to land (before quitting).
func flushLog() { Log.queue.sync {} }

private enum Log {
    static let queue = DispatchQueue(label: "capipaste.log", qos: .utility)
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Capipaste.log")
}

/// Apps where a pasted image beats pasted text (Claude Code attaches the image and drops the note),
/// so those get text only; the note already carries the saved image path.
enum Terminals {
    static let bundleIDs: Set<String> = [
        "com.apple.Terminal", "com.cmuxterm.app", "com.mitchellh.ghostty", "com.googlecode.iterm2",
        "dev.warp.Warp-Stable", "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty",
        "app.crynta.terax", "com.raphaelamorim.rio", "co.zeit.hyper", "com.termius-dmg.mac",
    ]

    static func contains(_ app: NSRunningApplication?) -> Bool {
        app?.bundleIdentifier.map(bundleIDs.contains) ?? false
    }
}

/// Launch arguments that drive the test hooks (`-autocapture`, `-dictate`, …). Empty unless built with
/// TESTHOOKS (`scripts/install.sh hooks`): a released app holds Screen Recording, Microphone and
/// Accessibility, and must not be steerable by whoever launches it.
var hookArguments: [String] {
    #if TESTHOOKS
    CommandLine.arguments
    #else
    []
    #endif
}
