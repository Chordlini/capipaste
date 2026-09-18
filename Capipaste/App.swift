import AVFoundation
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let capture = Self("capture", default: .init(.s, modifiers: [.command, .shift]))
    static let dictate = Self("dictate")  // optional shortcut; hold-to-talk is the main trigger
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
        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in self?.startDictation() }
        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in self?.dictation?.finish() }
        refreshMics()
        permissions.refresh()
        pushToTalk = PushToTalk(
            onStart: { [weak self] in self?.startDictation() },
            onStop: { [weak self] in self?.dictation?.finish() })
        Task { await stt.warmUp() }
        if updater.checkOnLaunch { Task { await updater.check() } }
        showSettingsOnFirstRun()
        openDemoIfRequested()
        if CommandLine.arguments.contains("-autocapture") { capture() }
        transcribeFileIfRequested()
        menuShotIfRequested()
        dictateIfRequested()
        settingsCheckIfRequested()
        updateCheckIfRequested()
    }

    func refreshMics() {
        mics = AudioInput.all()
        if let uid = micUID, !mics.contains(where: { $0.uid == uid }) { micUID = nil }
    }

    var selectedMic: AudioInput? {
        mics.first { $0.uid == micUID } ?? mics.first { $0.isDefault }
    }

    func capture() {
        let source = NSWorkspace.shared.frontmostApplication
        trace("capture: hotkey, card open=\(card != nil), screen access=\(CGPreflightScreenCaptureAccess())")
        guard card == nil else { card?.focus(); return }
        if !CGPreflightScreenCaptureAccess() {
            // macOS shows its own prompt; the capture works once access is granted.
            CGRequestScreenCaptureAccess()
        }
        Task {
            let url = await Capture.region()
            trace("capture: region file=\(url?.path ?? "none")")
            guard let url, let image = NSImage(contentsOf: url) else { return }
            try? FileManager.default.removeItem(at: url)
            await open(image, returnTo: source)
        }
    }

    private func open(_ image: NSImage, returnTo source: NSRunningApplication? = nil) async {
        trace("open: image \(image.size), mic status=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        card = CaptureCard(image: image, mic: selectedMic, stt: stt, textOnly: Terminals.contains(source)) { [weak self] in
            self?.card = nil
            // Hand focus back so ⌘V lands where the capture started.
            source?.activate()
        }
        trace("open: card created")
    }

    /// `-demo <png>` opens the card on an existing image (testing, README shots).
    private func openDemoIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-demo"), i + 1 < args.count,
              let image = NSImage(contentsOfFile: args[i + 1]) else { return }
        Task { await open(image) }
    }

    /// `-updatecheck` runs one update check and logs the outcome (testing).
    private func updateCheckIfRequested() {
        guard CommandLine.arguments.contains("-updatecheck") else { return }
        Task {
            await updater.check()
            trace("updater: status=\(updater.status) current=\(updater.currentVersion) latest=\(updater.release?.version ?? "none")")
            NSApp.terminate(nil)
        }
    }

    /// `-settingscheck` opens Settings and logs the window it made (testing).
    private func settingsCheckIfRequested() {
        guard CommandLine.arguments.contains("-settingscheck") else { return }
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
        let args = CommandLine.arguments
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
        let args = CommandLine.arguments
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

    /// `-sttfile <audio>` runs the active speech model over a file and logs the result (testing).
    private func transcribeFileIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-sttfile"), i + 1 < args.count else { return }
        Task {
            do {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[i + 1]))
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
                let text = await stt.finish(expectSpeech: true)
                trace("sttfile: result=\(text ?? "nil (failed)") problem=\(stt.problem ?? "none")")
            } catch {
                trace("sttfile: \(error)")
            }
        }
    }

    /// Hold-to-talk: a bar with the live transcript, no screenshot.
    func startDictation() {
        guard dictation == nil else { return }
        let source = NSWorkspace.shared.frontmostApplication
        trace("dictation: start from \(source?.localizedName ?? "unknown")")
        dictation = DictationBar(mic: selectedMic, stt: stt, returnTo: source,
                                 autoPaste: permissions.canDictateHandsFree) { [weak self] in
            self?.dictation = nil
        }
    }

    func openSettings() {
        SettingsWindow.shared.show(
            SettingsView()
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
        let args = CommandLine.arguments
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

/// Appends a line to ~/Library/Logs/Capipaste.log (capture-flow breadcrumbs).
func trace(_ message: String) {
    let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Capipaste.log")
    let line = "\(Date().formatted(.iso8601)) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}

/// Apps where a pasted image beats pasted text (Claude Code attaches the image and drops the note),
/// so those get text only; the note already carries the saved image path.
enum Terminals {
    static let bundleIDs: Set<String> = [
        "com.apple.Terminal", "com.cmuxterm.app", "com.mitchellh.ghostty", "com.googlecode.iterm2",
        "dev.warp.Warp-Stable", "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty",
    ]

    static func contains(_ app: NSRunningApplication?) -> Bool {
        app?.bundleIdentifier.map(bundleIDs.contains) ?? false
    }
}
