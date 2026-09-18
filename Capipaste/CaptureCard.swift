import AVFoundation
import SwiftUI

/// Floating panel that hosts the card for one capture.
@MainActor
final class CaptureCard {
    private let panel: KeyPanel
    private let model: CardModel
    private var hosting: NSView?
    private var scrollMonitor: Any?

    init(image: NSImage, mic: AudioInput?, stt: STT, textOnly: Bool = false, onClose: @escaping () -> Void) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let model = CardModel(image: image, mic: mic, stt: stt, screen: screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900))
        model.textOnly = textOnly
        self.model = model
        panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false // drags belong to the pen
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: CardView(model: model).padding(40))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        self.hosting = hosting

        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                                         y: visible.midY - panel.frame.height / 2))
        }

        // Two-finger scroll pans the zoomed screenshot.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak model, panel] event in
            guard let model, event.window === panel, model.zoom > 1 else { return event }
            model.pan(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
            return nil
        }

        model.relayout = { [weak self] in
            // Let SwiftUI lay out the new size first, then grow/shrink around the same centre.
            DispatchQueue.main.async { self?.fit() }
        }
        model.close = { [panel, weak self] in
            if let monitor = self?.scrollMonitor { NSEvent.removeMonitor(monitor) }
            panel.orderOut(nil)
            onClose()
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        trace("card: panel frame=\(panel.frame), visible=\(panel.isVisible), key=\(panel.isKeyWindow)")
        model.startListening()
        trace("card: listening=\(model.recording), failure=\(model.failure ?? "none")")
        snapshotIfRequested(hosting)
        autosubmitIfRequested(model)
    }

    /// `-snapshot <png>` writes the rendered card after 3 s (visual checks without Screen Recording).
    private func snapshotIfRequested(_ view: NSView) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-snapshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    /// `-autosubmit`: draws/erases test strokes, then presses Enter for you after 9 s (speak meanwhile).
    private func autosubmitIfRequested(_ model: CardModel) {
        guard CommandLine.arguments.contains("-autosubmit") else { return }
        Task {
            try? await Task.sleep(for: .seconds(9))
            // `-addshot <png>`: a second capture joins the note (and gets the test marks)
            let extra = CommandLine.arguments.firstIndex(of: "-addshot").map { CommandLine.arguments[$0 + 1] }
            if let extra, let image = NSImage(contentsOfFile: extra) {
                self.add(image)
                trace("card: shots=\(model.shots.count) showing=\(model.index)")
                try? await Task.sleep(for: .seconds(1))
                if let hosting, let i = CommandLine.arguments.firstIndex(of: "-snapshot"),
                   let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1] + "-2.png"))
                }
            }
            for x in stride(from: 40.0, through: 200, by: 8) { model.drag(to: CGPoint(x: x, y: 60 + x / 4)) }
            model.endDrag()
            // Erase the middle: expect the line to split in two, and undo to restore it.
            model.tool = .erase
            model.drag(to: CGPoint(x: 120, y: 90)); model.endDrag()
            let split = model.strokes.count
            model.undo()
            let restored = model.strokes.count
            model.drag(to: CGPoint(x: 120, y: 90)); model.endDrag()
            trace("card: erase split=\(split) (want 2), undo=\(restored) (want 1), final=\(model.strokes.count)")
            // Zoomed drawing: a small circle at the view centre must land at the image centre.
            model.tool = .draw
            let centre = CGPoint(x: model.shotSize.width / 2, y: model.shotSize.height / 2)
            model.zoom(to: 2, around: centre)
            for a in stride(from: 0.0, through: 2 * .pi, by: 0.2) {
                model.drag(to: CGPoint(x: centre.x + 20 * cos(a), y: centre.y + 20 * sin(a)))
            }
            model.endDrag()
            let c = model.strokes.last?.points.first ?? .zero
            trace("card: zoom=\(model.zoom) offset=\(model.offset) circle starts at image \(c), image size \(model.image.size)")
            model.resetZoom()
            // Shapes: arrow, box and blur each add one; a box erased at its edge goes away.
            for (tool, from, to) in [(Tool.arrow, CGPoint(x: 30, y: 150), CGPoint(x: 150, y: 110)),
                                     (.box, CGPoint(x: 200, y: 20), CGPoint(x: 330, y: 90)),
                                     (.blur, CGPoint(x: 20, y: 60), CGPoint(x: 260, y: 100))] {
                model.tool = tool
                model.drag(to: from); model.drag(to: to); model.endDrag()
            }
            let shapes = model.strokes.count
            model.tool = .erase
            model.drag(to: CGPoint(x: 200, y: 50)); model.endDrag()
            trace("card: shapes added=\(shapes) after erasing box=\(model.strokes.count) (want one less)")
            model.undo()
            // `-note <text>`: type the note instead of speaking it
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "-note"), i + 1 < args.count {
                model.text = args[i + 1]
                model.textChanged(args[i + 1])
            }
            trace("card: autosubmit")
            model.submit()
        }
    }

    func focus() {
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Out of the way while you pick the next region; the mic keeps recording.
    func hide() { panel.orderOut(nil) }

    func add(_ image: NSImage) {
        model.add(image)
        focus()
    }

    private func fit() {
        guard let size = hosting?.fittingSize else { return }
        let old = panel.frame
        panel.setFrame(NSRect(x: old.midX - size.width / 2, y: old.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

enum Tool {
    case draw, arrow, box, blur, erase

    var shape: Stroke.Kind? {
        switch self {
        case .arrow: .arrow
        case .box: .box
        case .blur: .blur
        case .draw, .erase: nil
        }
    }
}

/// One screenshot in the card, with its own marks.
struct Shot {
    let image: NSImage
    var strokes: [Stroke] = []
    var history: [[Stroke]] = []
    /// Text read off the capture, started when it's added.
    let ocr: Task<String, Never>
}

@MainActor @Observable
final class CardModel {
    let stt: STT
    private let mic: AudioInput?
    private let recorder = Recorder()
    private let screen: CGSize
    var close: () -> Void = {}
    /// The card's size changes (a shot added, removed or switched).
    var relayout: () -> Void = {}

    private(set) var shots: [Shot] = []
    private(set) var index = 0
    var image: NSImage { shots[index].image }
    var strokes: [Stroke] {
        get { shots[index].strokes }
        set { shots[index].strokes = newValue }
    }
    private var history: [[Stroke]] {
        get { shots[index].history }
        set { shots[index].history = newValue }
    }

    var text = ""
    private var liveEcho = ""
    var userEdited = false
    var recording = false
    var finishing = false
    var tidying = false
    var copied = false
    var failure: String?
    var startedAt = Date()
    var stoppedAfter: TimeInterval?
    var levels = [Float](repeating: 0, count: 96)
    /// Whether the mic picked up anything louder than room noise this take.
    private var heardSpeech: Bool { loudBuffers >= 8 }
    private var loudBuffers = 0
    private var levelSum: Float = 0
    private var levelCount = 0
    /// Copy only the note (with the image path), for terminals.
    var textOnly = false
    private var peakLevel: Float = 0
    /// True while the audio device is being opened on a background thread.
    private var startingMic = false

    var tool: Tool = .draw
    var current: Stroke?
    /// Each capture as a mosaic, shown through blur boxes (made on first use).
    @ObservationIgnored private var mosaics: [ObjectIdentifier: NSImage] = [:]
    var mosaic: NSImage? {
        let key = ObjectIdentifier(image)
        if let cached = mosaics[key] { return cached }
        let made = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            .flatMap(Output.pixelated).map { NSImage(cgImage: $0, size: image.size) }
        mosaics[key] = made
        return made
    }

    init(image: NSImage, mic: AudioInput?, stt: STT, screen: CGSize) {
        self.mic = mic
        self.stt = stt
        self.screen = screen
        add(image)
    }

    /// Another capture for the same note; recording keeps going.
    func add(_ image: NSImage) {
        let read = Task { await OCR.text(in: image) }
        shots.append(Shot(image: image, ocr: read))
        // Names on screen are what you're likely to say: teach them to the speech model for this take.
        Task { [stt, shots] in
            var words: [String] = []
            for shot in shots { words += Vocabulary.identifiers(in: await shot.ocr.value) }
            stt.sessionWords = words
        }
        select(shots.count - 1)
    }

    func select(_ i: Int) {
        guard shots.indices.contains(i), current == nil else { return }
        index = i
        resetZoom()
        relayout()
    }

    func remove(_ i: Int) {
        guard shots.count > 1, shots.indices.contains(i) else { return }
        shots.remove(at: i)
        index = min(index, shots.count - 1)
        resetZoom()
        relayout()
    }

    /// Fill up to 80% of the screen (minus the strip, thumbnails, note and footer), never upscaled past 1:1.
    var fitScale: CGFloat { fitScale(for: image) }
    func fitScale(for image: NSImage) -> CGFloat {
        let size = image.size
        return min(screen.width * 0.8 / size.width, (screen.height * 0.8 - 190 - (shots.count > 1 ? 70 : 0)) / size.height, 1)
    }
    var shotSize: CGSize { CGSize(width: image.size.width * fitScale, height: image.size.height * fitScale) }

    // MARK: Zoom

    static let maxZoom: CGFloat = 6
    var zoom: CGFloat = 1
    /// Offset of the zoomed image inside the frame (always ≤ 0).
    var offset: CGPoint = .zero
    private var pinchStart: (zoom: CGFloat, offset: CGPoint)?

    private var pointsPerImagePoint: CGFloat { fitScale * zoom }

    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) / pointsPerImagePoint, y: (p.y - offset.y) / pointsPerImagePoint)
    }

    var toView: CGAffineTransform {
        CGAffineTransform(a: pointsPerImagePoint, b: 0, c: 0, d: pointsPerImagePoint, tx: offset.x, ty: offset.y)
    }

    /// Zooms keeping the image point under `anchor` (frame coordinates) still.
    func zoom(to value: CGFloat, around anchor: CGPoint) {
        let fixed = toImage(anchor)
        zoom = min(max(value, 1), Self.maxZoom)
        offset = CGPoint(x: anchor.x - fixed.x * pointsPerImagePoint, y: anchor.y - fixed.y * pointsPerImagePoint)
        clampOffset()
    }

    func pinchChanged(_ magnification: CGFloat, at anchor: CGPoint) {
        if pinchStart == nil { pinchStart = (zoom, offset) }
        guard let start = pinchStart else { return }
        zoom = start.zoom
        offset = start.offset
        zoom(to: start.zoom * magnification, around: anchor)
    }

    func pinchEnded() { pinchStart = nil }

    func zoomStep(_ factor: CGFloat) {
        zoom(to: zoom * factor, around: CGPoint(x: shotSize.width / 2, y: shotSize.height / 2))
    }

    func resetZoom() {
        zoom = 1
        offset = .zero
    }

    func pan(by delta: CGSize) {
        offset.x += delta.width
        offset.y += delta.height
        clampOffset()
    }

    private func clampOffset() {
        offset.x = min(0, max(offset.x, shotSize.width - shotSize.width * zoom))
        offset.y = min(0, max(offset.y, shotSize.height - shotSize.height * zoom))
    }

    var cardWidth: CGFloat { max(shotSize.width, 440) }

    static let micDenied = "Microphone access is off. Type your note, or allow it in System Settings › Privacy › Microphone."

    func startListening() {
        guard let mic else {
            failure = "No microphone found. Type your note instead."
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // Ask without blocking the card; start once the answer comes back.
            failure = "Allow microphone access to dictate, or just type."
            NSApp.activate()
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                trace("card: mic granted=\(granted)")
                failure = granted ? nil : Self.micDenied
                if granted, !userEdited, !copied { startListening() }
            }
            return
        default:
            failure = Self.micDenied
            return
        }
        failure = nil
        loudBuffers = 0
        levelSum = 0
        levelCount = 0
        peakLevel = 0
        stt.begin()
        AppModel.shared.tidy.prewarm()
        startedAt = .now
        stoppedAfter = nil
        startingMic = true
        // AVAudioEngine talks to CoreAudio, which can block for a long time on a
        // misbehaving device (aggregates, Continuity mics). Never do that on the main
        // thread: the card would freeze with it.
        let recorder = self.recorder
        trace("card: opening mic \(mic.name)")
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try recorder.start(device: mic) { samples, level in
                    Task { @MainActor in self?.receive(samples, level) }
                }
                trace("card: mic engine started")
                await MainActor.run {
                    guard let self, self.startingMic else { return recorder.stop() }
                    self.startingMic = false
                    self.recording = true
                    self.startedAt = .now
                }
            } catch {
                trace("card: mic start threw \(error)")
                await MainActor.run {
                    guard let self else { return }
                    self.startingMic = false
                    self.stt.cancel()
                    self.failure = "Couldn't open \(mic.name)."
                }
            }
        }
        // If the device never answers, say so instead of leaving a dead card.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            trace("card: mic watchdog starting=\(self.startingMic) recording=\(self.recording)")
            guard self.startingMic, !self.recording else { return }
            self.startingMic = false
            self.stt.cancel()
            self.failure = "\(mic.name) isn't responding. Type your note, or pick another microphone."
            trace("card: mic start timed out on \(mic.name)")
        }
    }

    private func receive(_ samples: [Float], _ level: Float) {
        guard recording else { return }
        levels.removeFirst()
        levels.append(level)
        // ponytail: "speech" = at least 8 loud tap buffers (~0.8 s); tune if quiet voices get missed
        levelSum += level
        levelCount += 1
        if level > 0.6 { loudBuffers += 1 }
        peakLevel = max(peakLevel, level)
        stt.feed(samples)
    }

    func liveChanged(_ live: String) {
        guard !userEdited, !live.isEmpty else { return }
        liveEcho = live
        text = live
    }

    func textChanged(_ new: String) {
        guard new != liveEcho, !userEdited else { return }
        // Typing takes over: stop listening so speech can't overwrite the edit.
        userEdited = true
        stopRecording()
        stt.cancel()
    }

    private func stopRecording() {
        startingMic = false
        guard recording else { return }
        recorder.stop()
        recording = false
        stoppedAfter = Date().timeIntervalSince(startedAt)
        levels = levels.map { _ in 0 }
    }

    func submit() {
        guard !finishing, !copied else { return }
        Task {
            if recording {
                stopRecording()
                trace("card: submit, peak=\(peakLevel) avg=\(levelSum / Float(max(levelCount, 1))) loud=\(loudBuffers)/\(levelCount) heard speech=\(heardSpeech)")
                finishing = true
                let final = await stt.finish(expectSpeech: heardSpeech)
                finishing = false
                guard let final else {
                    // Keep the card: ask for a repeat and listen again.
                    trace("card: transcription failed twice, asking to repeat")
                    NSSound(named: "Basso")?.play()
                    startListening()
                    failure = "Transcription failed. Say it one more time."
                    return
                }
                if !final.isEmpty { text = final }
                if !userEdited {
                    finishing = true
                    tidying = true
                    var screen = ""
                    for shot in shots { screen += await shot.ocr.value + "\n" }
                    if let tidy = await AppModel.shared.tidy.rewrite(text, screen: screen) { text = tidy }
                    tidying = false
                    finishing = false
                }
            }
            var pngs: [Data] = []
            for shot in shots {
                guard let png = Output.render(shot.image, strokes: shot.strokes, lineWidth: Stroke.width / fitScale(for: shot.image)) else {
                    failure = "Couldn't render the screenshot."
                    return
                }
                pngs.append(png)
            }
            do {
                let mode = OCR.Mode.current
                let wantsOCR = mode == .always || (mode == .terminals && textOnly)
                var screenTexts: [String] = []
                for shot in shots { screenTexts.append(wantsOCR ? await shot.ocr.value : "") }
                let saved = try Output.deliver(pngs: pngs, note: text, screenTexts: screenTexts, textOnly: textOnly)
                trace("card: delivered \(saved.map(\.lastPathComponent)), text only=\(textOnly)")
            } catch {
                failure = "Couldn't save: \(error.localizedDescription)"
                return
            }
            copied = true
            NSSound(named: "Pop")?.play()
            try? await Task.sleep(for: .milliseconds(450))
            close()
        }
    }

    func cancel() {
        stopRecording()
        stt.cancel()
        close()
    }

    // MARK: Drawing

    static let eraserRadius: CGFloat = 10
    private var gestureStarted = false

    /// `viewPoint` is in the screenshot frame's coordinates; strokes are kept in image points.
    func drag(to viewPoint: CGPoint) {
        let point = toImage(viewPoint)
        if !gestureStarted {
            // One undo step per drag, whatever the tool did.
            gestureStarted = true
            history.append(strokes)
        }
        if let shape = tool.shape {
            // Shapes stretch from where the drag started to where it is now.
            if current == nil { current = Stroke(kind: shape, points: [point, point]) }
            current?.points[1] = point
            return
        }
        switch tool {
        case .arrow, .box, .blur:
            break
        case .draw:
            if current == nil { current = Stroke(points: []) }
            // Fill gaps from fast drags so the eraser can cut anywhere along the line.
            if let last = current?.points.last {
                let steps = Int(hypot(point.x - last.x, point.y - last.y) * pointsPerImagePoint / 2)
                for i in stride(from: 1, to: steps, by: 1) {
                    let t = CGFloat(i) / CGFloat(steps)
                    current?.points.append(CGPoint(x: last.x + (point.x - last.x) * t, y: last.y + (point.y - last.y) * t))
                }
            }
            current?.points.append(point)
        case .erase:
            // Cut out only the points under the eraser, splitting strokes into the pieces that remain.
            let radius = Self.eraserRadius / pointsPerImagePoint
            strokes = strokes.flatMap { stroke -> [Stroke] in
                guard stroke.kind == .pen else { return stroke.touches(point, radius: radius) ? [] : [stroke] }
                var pieces: [Stroke] = []
                var run: [CGPoint] = []
                for p in stroke.points {
                    if hypot(p.x - point.x, p.y - point.y) * pointsPerImagePoint <= Self.eraserRadius {
                        if !run.isEmpty { pieces.append(Stroke(points: run)); run = [] }
                    } else {
                        run.append(p)
                    }
                }
                if !run.isEmpty { pieces.append(Stroke(points: run)) }
                return pieces
            }
        }
    }

    func endDrag() {
        gestureStarted = false
        // A click with a shape tool draws nothing.
        if let stroke = current, stroke.kind == .pen || stroke.rect.width + stroke.rect.height > 6 / pointsPerImagePoint {
            strokes.append(stroke)
        } else if current != nil {
            history.removeLast()
        }
        current = nil
        if tool == .erase, history.last?.flatMap(\.points).count == strokes.flatMap(\.points).count,
           history.last?.count == strokes.count {
            history.removeLast() // eraser touched nothing
        }
    }

    func undo() {
        if let previous = history.popLast() { strokes = previous }
    }

    var canUndo: Bool { !history.isEmpty }
}

