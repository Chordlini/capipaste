import AVFoundation
import SwiftUI

/// The hold-to-talk bar: no screenshot, just the waveform and what you're saying.
@MainActor
final class DictationBar {
    private let panel: KeyPanel
    let model: DictationModel

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

        model.expanded = UserDefaults.standard.string(forKey: "hudSize") == "large"
        // Bottom-aligned so a growing pill stays put on screen while the panel jumps to its new size.
        let hosting = NSHostingView(rootView: DictationView(model: model).padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom))
        hosting.sizingOptions = [] // the panel is sized here, not by the view
        panel.contentView = hosting
        let pill = DictationView.size(expanded: model.expanded)
        panel.setContentSize(NSSize(width: pill.width + 60, height: pill.height + 60))

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                                         y: visible.minY + visible.height * 0.16))
        }
        // Hover opens the small bar. Polled: neither onHover nor a tracking area fires for this panel while
        // Capipaste isn't the active app, which is always. ponytail: 10 Hz only while a small bar is up.
        if !model.expanded {
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak panel, weak model] timer in
                MainActor.assumeIsolated {
                    guard let panel, let model, panel.isVisible, !model.expanded else { return timer.invalidate() }
                    guard panel.frame.insetBy(dx: 30, dy: 30).contains(NSEvent.mouseLocation) else { return }
                    // Panel first, unanimated, so the small pill doesn't slide while the frame catches up.
                    model.grow()
                    panel.contentView?.layoutSubtreeIfNeeded()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { model.expanded = true }
                }
            }
        }
        // Grows once (hover or an error), anchored bottom-centre; never shrinks within a take.
        model.grow = { [panel] in
            let old = panel.frame, new = DictationView.size(expanded: true)
            panel.setFrame(NSRect(x: old.midX - (new.width + 60) / 2, y: old.minY,
                                  width: new.width + 60, height: new.height + 60), display: true)
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
    /// A small bar can't hold a sentence: an error opens it up.
    var failure: String? { didSet { if failure != nil { expanded = true } } }
    /// Large bar (live words under the waveform); the small one opens up on hover, for this take.
    var expanded = false { didSet { if expanded, !oldValue { grow() } } }
    var grow: () -> Void = {}
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
    var live: String {
        #if TESTHOOKS
        if let shown { return shown }
        #endif
        return stt.live
    }
    #if TESTHOOKS
    /// `-dictate <seconds> <words>`: the words stand in for speech, three a second (testing the bar).
    private let scripted: String? = {
        let args = hookArguments
        guard let i = args.firstIndex(of: "-dictate"), i + 2 < args.count, !args[i + 2].hasPrefix("-") else { return nil }
        return args[i + 2]
    }()
    private var shown: String?
    #endif

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
        #if TESTHOOKS
        if let scripted {
            Task {
                let words = scripted.split(separator: " ")
                for n in 1...words.count where !over {
                    try? await Task.sleep(for: .milliseconds(330))
                    shown = words.prefix(n).joined(separator: " ")
                }
            }
        }
        #endif
        AppModel.shared.tidy.prewarm()
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
        // After the mic start is queued: a big image on the clipboard mustn't delay recording.
        if autoPaste { PasteSession.snapshot() }
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
            var spoken = take.text
            let audio = take.audio
            #if TESTHOOKS
            if let scripted { spoken = scripted }
            #endif
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

    /// The pill alone, without the 30 pt the panel keeps around it for the shadow.
    static func size(expanded: Bool) -> CGSize { expanded ? CGSize(width: 420, height: 132) : CGSize(width: 180, height: 40) }

    var body: some View {
        let large = model.expanded
        let size = Self.size(expanded: large)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(model.recording ? Color.ink : .secondary)
                        .frame(width: 8, height: 8)
                    if large {
                        TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
                            let seconds = Int(context.date.timeIntervalSince(model.startedAt))
                            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                                .monospacedDigit()
                        }
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.black.opacity(0.7))

                if model.done, !large {
                    Spacer(minLength: 0)
                    check
                    Spacer(minLength: 0)
                } else {
                    Waveform(levels: model.levels, live: model.recording)
                        .frame(height: large ? 30 : 24)
                }
                if model.done, large { check }
            }
            if large {
                // Newest words at the bottom; older lines slide up under a fade.
                Text(caption)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(model.failure != nil ? Color.ink : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 66, maxHeight: 66, alignment: model.failure != nil ? .topLeading : .bottomLeading)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: model.failure != nil ? .black : .clear, location: 0), .init(color: .black, location: 0.2)],
                                         startPoint: .top, endPoint: .bottom))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, large ? 18 : 16)
        .frame(width: size.width, height: size.height)
        .background(.white.opacity(0.98), in: .rect(cornerRadius: large ? 22 : 20, style: .continuous))
        .clipShape(.rect(cornerRadius: large ? 22 : 20, style: .continuous)) // mid-grow, words stay inside
        .overlay(RoundedRectangle(cornerRadius: large ? 22 : 20, style: .continuous).strokeBorder(.primary.opacity(0.10)))
        // two soft passes hug the pill instead of boxing it in
        .shadow(color: .black.opacity(0.13), radius: 18, y: 8)
        .shadow(color: .black.opacity(0.07), radius: 4, y: 1)
        .environment(\.colorScheme, .light)
    }

    private var check: some View {
        Label(model.pasted ? "Pasted" : "Copied", systemImage: "checkmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.glacier)
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
