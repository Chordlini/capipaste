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
        var closed = false
        model.close = { [panel] in
            guard !closed else { return }
            closed = true
            panel.orderOut(nil)
            // Break panel → view → model → this closure → panel, so each take is freed.
            DispatchQueue.main.async { panel.contentView = nil }
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
    var tidying = false
    var done = false
    var failure: String?
    var pasted: Bool { autoPaste }
    /// Cancelled, finished or never started: a mic that comes up late closes straight away.
    private var over = false
    var levels = [Float](repeating: 0, count: 96)
    var startedAt = Date()
    private var loudBuffers = 0
    private var buffers = 0
    private var peak: Float = 0
    private var floor: Float = 1
    private var quietSamples = 0
    private var heardSpeech: Bool { loudBuffers >= 8 }
    private var releasedAt = Date()

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
        AppModel.shared.tidy.prewarm()
        if autoPaste { PasteSession.snapshot() }
        startedAt = .now
        loudBuffers = 0
        let recorder = self.recorder
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await recorder.start(device: mic) { samples, level in
                    Task { @MainActor in self?.receive(samples, level) }
                }
                trace("dictation: mic engine started on \(mic.name)")
                await MainActor.run {
                    // Let go (or a shortcut) before the device opened: don't leave it on.
                    guard let self, !self.over else { return recorder.stop() }
                    self.recording = true
                }
            } catch {
                trace("dictation: mic start threw \(error)")
                await MainActor.run { self?.failure = "Couldn't open \(mic.name)." }
            }
        }
    }

    private func receive(_ samples: [Float], _ level: Float) {
        guard recording else { return }
        levels = Array(levels.dropFirst()) + [level] // one change per buffer, not two
        // Same cap as the card: a key-up that never arrives must not leave an open mic.
        if Date().timeIntervalSince(startedAt) > CardModel.maxTake {
            trace("dictation: reached \(Int(CardModel.maxTake)) s, finishing")
            finish()
        }
        buffers += 1
        peak = max(peak, level)
        if level > 0.57 { loudBuffers += 1 }
        if level > 0 { floor = min(floor, level) }
        // ponytail: "quiet" = under the quietest buffer this take + 0.1 (6 dB). In practice that's ~-54 dB, so a
        // noisy room never counts as quiet and keeps the 300 ms tail (slower, never clipped); raise if that's common.
        quietSamples = level < floor + 0.1 ? quietSamples + samples.count : 0
        stt.feed(samples)
    }

    func finish() {
        guard !finishing, !done, !over else { return }
        over = true
        releasedAt = .now
        // People let go of the key on their last word: keep listening a moment so it isn't cut off ("blue" → "bl").
        // Already ~150 ms (2400 samples) of quiet before the key-up: nothing left to catch, stop now.
        let tail = quietSamples >= 2_400 ? 0 : 300
        Task {
            if tail > 0 { try? await Task.sleep(for: .milliseconds(tail)) }
            guard !cancelled else { return }
            stopAndDeliver(tail: tail)
        }
    }

    private func stopAndDeliver(tail: Int) {
        recorder.stop()
        recording = false
        trace("dictation: released after \(buffers) buffers, tail \(tail) ms, peak level \(peak), loud \(loudBuffers)")
        // No mic (or no permission): keep saying why instead of "didn't catch that".
        if failure != nil {
            stt.cancel()
            Task { try? await Task.sleep(for: .seconds(1.5)); close() }
            return
        }
        finishing = true
        Task {
            let take = await stt.finish(expectSpeech: heardSpeech)
            let spoken = take.text, audio = take.audio
            finishing = false
            guard !cancelled else { return }
            guard let spoken, !spoken.isEmpty else {
                failure = "Didn't catch that. Hold again and say it once more."
                trace("dictation: nothing transcribed")
                NSSound(named: "Basso")?.play()
                try? await Task.sleep(for: .seconds(2))
                close()
                return
            }
            tidying = true
            let note = await AppModel.shared.tidy.rewrite(spoken) ?? spoken
            tidying = false
            guard !cancelled else { return }
            text = note
            Output.deliver(text: note, audio: audio, pasting: autoPaste)
            done = true
            trace("dictation: delivered \(spoken.count) chars, paste=\(autoPaste)")
            NSSound(named: "Pop")?.play()
            // The bar never takes focus, so usually you're still there: only switch back (and wait) if not.
            let away = returnTo.map { $0 != NSWorkspace.shared.frontmostApplication } ?? false
            if away { returnTo?.activate() }
            if autoPaste {
                if away { try? await Task.sleep(for: .milliseconds(70)) }
                Output.paste()
            }
            trace("dictation: key-up to \(autoPaste ? "⌘V" : "copy") \(Int(Date().timeIntervalSince(releasedAt) * 1000)) ms")
            try? await Task.sleep(for: .milliseconds(220))
            close()
        }
    }

    private var cancelled = false

    func cancel() {
        over = true
        cancelled = true
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
                Label(model.pasted ? "Pasted" : "Copied", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.glacier)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
        .background(.white.opacity(0.92), in: .capsule)
        .overlay(Capsule().strokeBorder(.primary.opacity(0.10)))
        // two soft passes hug the pill instead of boxing it in
        .shadow(color: .black.opacity(0.13), radius: 18, y: 8)
        .shadow(color: .black.opacity(0.07), radius: 4, y: 1)
        .environment(\.colorScheme, .light)
    }

    private var caption: String {
        if let failure = model.failure { return failure }
        if model.done { return model.text }
        if model.tidying { return "Tidying…" }
        if model.finishing { return model.live.isEmpty ? "Transcribing…" : model.live }
        if !model.live.isEmpty { return model.live }
        return model.recording ? "Listening… let go when you're done" : "Starting the mic…"
    }
}
