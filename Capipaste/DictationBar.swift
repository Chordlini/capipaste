import AVFoundation
import SwiftUI

/// The hold-to-talk bar: no screenshot, just the waveform and what you're saying.
@MainActor
final class DictationBar {
    private let panel: KeyPanel
    private let model: DictationModel

    init(mic: AudioInput?, stt: STT, returnTo: NSRunningApplication?, autoPaste: Bool, onClose: @escaping () -> Void) {
        model = DictationModel(mic: mic, stt: stt, returnTo: returnTo, autoPaste: autoPaste)
        panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: DictationView(model: model).padding(30))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                                         y: visible.minY + visible.height * 0.16))
        }
        model.close = { [panel] in
            panel.orderOut(nil)
            onClose()
        }
        // Stays non-key: the point is not to steal focus from what you're typing into.
        panel.orderFrontRegardless()
        model.start()
    }

    /// Key released: transcribe what was said, copy, paste, close.
    func finish() { model.finish() }
    func cancel() { model.cancel() }
}

@MainActor @Observable
final class DictationModel {
    private let mic: AudioInput?
    private let stt: STT
    private let returnTo: NSRunningApplication?
    private let autoPaste: Bool
    private let recorder = Recorder()
    var close: () -> Void = {}

    var text = ""
    var recording = false
    var finishing = false
    var done = false
    var failure: String?
    var levels = [Float](repeating: 0, count: 96)
    var startedAt = Date()
    private var loudBuffers = 0
    private var heardSpeech: Bool { loudBuffers >= 8 }

    init(mic: AudioInput?, stt: STT, returnTo: NSRunningApplication?, autoPaste: Bool) {
        self.mic = mic
        self.stt = stt
        self.returnTo = returnTo
        self.autoPaste = autoPaste
    }

    var model: SpeechModel { stt.inUse }
    var live: String { stt.live }

    func start() {
        guard let mic else {
            failure = "No microphone found."
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            failure = "Allow microphone access in Settings first."
            return
        }
        stt.begin()
        startedAt = .now
        loudBuffers = 0
        let recorder = self.recorder
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try recorder.start(device: mic) { samples, level in
                    Task { @MainActor in self?.receive(samples, level) }
                }
                await MainActor.run { self?.recording = true }
            } catch {
                await MainActor.run { self?.failure = "Couldn't open \(mic.name)." }
            }
        }
    }

    private func receive(_ samples: [Float], _ level: Float) {
        levels.removeFirst()
        levels.append(level)
        if level > 0.6 { loudBuffers += 1 }
        stt.feed(samples)
    }

    func finish() {
        guard !finishing, !done else { return }
        finishing = true
        recorder.stop()
        recording = false
        Task {
            let spoken = await stt.finish(expectSpeech: heardSpeech)
            finishing = false
            guard let spoken, !spoken.isEmpty else {
                failure = "Didn't catch that. Hold again and say it once more."
                trace("dictation: nothing transcribed")
                NSSound(named: "Basso")?.play()
                try? await Task.sleep(for: .seconds(2))
                close()
                return
            }
            text = spoken
            Output.deliver(text: spoken)
            done = true
            trace("dictation: delivered \(spoken.count) chars, paste=\(autoPaste)")
            NSSound(named: "Pop")?.play()
            returnTo?.activate()
            if autoPaste {
                try? await Task.sleep(for: .milliseconds(140))
                Output.paste()
            }
            try? await Task.sleep(for: .milliseconds(650))
            close()
        }
    }

    func cancel() {
        recorder.stop()
        recording = false
        stt.cancel()
        close()
    }
}

struct DictationView: View {
    @Bindable var model: DictationModel

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                Circle()
                    .fill(model.recording ? Color.ink : .secondary)
                    .frame(width: 8, height: 8)
                TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(model.startedAt))
                    Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                        .monospacedDigit()
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.black.opacity(0.7))

            Waveform(levels: model.levels, live: model.recording)
                .frame(width: 120, height: 34)

            Text(caption)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(model.failure != nil ? Color.ink : .primary)
                .lineLimit(2)
                .frame(maxWidth: 420, alignment: .leading)
                .frame(minWidth: 220, alignment: .leading)

            if model.done {
                Label("Pasted", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.glacier)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
        .background(.white.opacity(0.78), in: .capsule)
        .background(.ultraThinMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
        .environment(\.colorScheme, .light)
    }

    private var caption: String {
        if let failure = model.failure { return failure }
        if model.done { return model.text }
        if model.finishing { return model.live.isEmpty ? "Transcribing…" : model.live }
        if !model.live.isEmpty { return model.live }
        return model.recording ? "Listening… let go when you're done" : "Starting the mic…"
    }
}
