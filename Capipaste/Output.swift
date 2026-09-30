import AppKit
import CoreImage

struct Stroke {
    static let width: CGFloat = 4
    static let color = CGColor(srgbRed: 1, green: 0.231, blue: 0.361, alpha: 1) // #FF3B5C

    enum Kind { case pen, arrow, box, blur }
    var kind: Kind = .pen
    /// Pen: the whole line. Arrow, box, blur: start and end.
    var points: [CGPoint]

    var rect: CGRect {
        guard let a = points.first, let b = points.last else { return .null }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Outline in card coordinates; `lineWidth` (image points) sizes the arrowhead.
    func path(_ transform: CGAffineTransform = .identity, lineWidth: CGFloat = Stroke.width) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first, let last = points.last else { return path }
        switch kind {
        case .pen:
            path.move(to: first, transform: transform)
            if points.count == 1 {
                path.addLine(to: first, transform: transform)
                return path
            }
            for i in 1..<points.count {
                let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
                path.addQuadCurve(to: mid, control: points[i - 1], transform: transform)
            }
            path.addLine(to: last, transform: transform)
        case .arrow:
            path.move(to: first, transform: transform)
            path.addLine(to: last, transform: transform)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = min(lineWidth * 4.5, hypot(last.x - first.x, last.y - first.y) * 0.5)
            for side in [-1.0, 1.0] {
                let a = angle + .pi + side * .pi / 6
                path.move(to: CGPoint(x: last.x + head * cos(a), y: last.y + head * sin(a)), transform: transform)
                path.addLine(to: last, transform: transform)
            }
        case .box, .blur:
            path.addRect(rect, transform: transform)
        }
        return path
    }

    /// Cuts out only the points under the eraser (image points), splitting pen strokes into the pieces
    /// that remain; shapes it touches go whole.
    static func erase(_ strokes: [Stroke], at point: CGPoint, radius: CGFloat) -> [Stroke] {
        strokes.flatMap { stroke -> [Stroke] in
            guard stroke.kind == .pen else { return stroke.touches(point, radius: radius) ? [] : [stroke] }
            var pieces: [Stroke] = []
            var run: [CGPoint] = []
            for p in stroke.points {
                if hypot(p.x - point.x, p.y - point.y) <= radius {
                    if !run.isEmpty { pieces.append(Stroke(points: run)); run = [] }
                } else {
                    run.append(p)
                }
            }
            if !run.isEmpty { pieces.append(Stroke(points: run)) }
            return pieces
        }
    }

    /// Whether the eraser at `p` (image points) touches this shape. Pen strokes are cut point by point instead.
    func touches(_ p: CGPoint, radius: CGFloat) -> Bool {
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
            let dx = b.x - a.x, dy = b.y - a.y
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / max(dx * dx + dy * dy, 0.0001)))
            return hypot(a.x + t * dx - p.x, a.y + t * dy - p.y) <= radius
        }
        let r = rect
        switch kind {
        case .pen: return false
        case .arrow: return near(points.first!, points.last!)
        case .blur: return r.insetBy(dx: -radius, dy: -radius).contains(p)
        case .box:
            let c = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            return (0..<4).contains { near(c[$0], c[($0 + 1) % 4]) }
        }
    }
}

enum Output {
    /// Menu bar › Paste includes › Image. Off: only the words (and whatever else is on) get pasted.
    static var includesImage: Bool { UserDefaults.standard.object(forKey: "pasteImage") as? Bool ?? true }

    /// Flattens the strokes (image points, `lineWidth` in image points) onto the full-resolution capture.
    static func render(_ image: NSImage, strokes: [Stroke], lineWidth: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cg.width, height = cg.height
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = cg.colorSpace?.model == .rgb ? cg.colorSpace! : sRGB
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        let scale = CGFloat(width) / image.size.width
        // Image points are top-left origin; bitmap is bottom-left.
        let flip = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: 0, ty: CGFloat(height))
        // Blur first so annotations stay sharp on top of it.
        let blurs = strokes.filter { $0.kind == .blur }
        if !blurs.isEmpty, let mosaic = pixelated(cg) {
            for blur in blurs {
                ctx.saveGState()
                ctx.addPath(blur.path(flip))
                ctx.clip()
                ctx.draw(mosaic, in: CGRect(x: 0, y: 0, width: width, height: height))
                ctx.restoreGState()
            }
        }
        ctx.setStrokeColor(Stroke.color)
        ctx.setLineWidth(lineWidth * scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in strokes where stroke.kind != .blur {
            ctx.addPath(stroke.path(flip, lineWidth: lineWidth))
            ctx.strokePath()
        }
        guard let flattened = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: flattened).representation(using: .png, properties: [:])
    }

    private static let ciContext = CIContext() // expensive to make; one is thread-safe to share

    /// The whole capture as a coarse mosaic; blur boxes show this through their clip.
    static func pixelated(_ cg: CGImage) -> CGImage? {
        let image = CIImage(cgImage: cg)
        // ponytail: ~70 blocks across; the 24 px floor keeps small captures from leaving a few blocks per letter,
        // which pixelation-reversing tools can read. Solid redaction if this ever has to resist a determined attacker.
        let block = max(24, Double(cg.width) / 70)
        let mosaic = image.clampedToExtent().applyingFilter("CIPixellate", parameters: ["inputScale": block]).cropped(to: image.extent)
        return ciContext.createCGImage(mosaic, from: image.extent)
    }

    /// Saves the PNGs and puts image(s) + note on the clipboard. Returns the saved files.
    @discardableResult
    static func deliver(pngs: [Data], note: String, context: String? = nil, screenTexts: [String] = [],
                        clip: Clip.Recording? = nil, clipBlurs: [Stroke] = [], textOnly: Bool = false,
                        audio: [Float] = []) throws -> [URL] {
        let folder = AppModel.capturesFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = stamp(in: folder)
        let many = pngs.count > 1
        var urls: [URL] = []
        for (i, png) in pngs.enumerated() {
            let url = folder.appendingPathComponent("Capipaste \(stamp)\(many ? " (\(i + 1))" : "").png")
            try png.write(to: url)
            urls.append(url)
        }

        // Text-only targets (terminals) still reach the images through the paths.
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = trimmed.isEmpty ? "" : trimmed + "\n\n"
        if let context { text += context + "\n\n" }
        for (i, screen) in screenTexts.enumerated() where !screen.isEmpty {
            text += "Text in the screenshot\(many ? " \(i + 1)" : ""):\n```text\n\(screen)\n```\n\n"
        }
        let image = includesImage
        if image { text += urls.enumerated().map { "[screenshot\(many ? " \($0.offset + 1)" : ""): \($0.element.path)]" }.joined(separator: "\n") }
        text = text.trimmingCharacters(in: .newlines)
        var movie: URL?
        if let clip {
            // The first frame is the (annotated) screenshot above; the rest show what happened next.
            if clipBlurs.isEmpty {
                let saved = folder.appendingPathComponent("Capipaste \(stamp).mov")
                try FileManager.default.moveItem(at: clip.movie, to: saved)
                movie = saved
                text += "\n[clip, \(clip.seconds) s: \(saved.path)]"
            } else {
                // ponytail: the video can't be blurred here, so it isn't kept; re-encode it blurred if that's missed
                try? FileManager.default.removeItem(at: clip.movie)
                text += "\n[clip, \(clip.seconds) s: video not kept, part of it is blurred; key frames follow]"
            }
            for (i, frame) in clip.frames.dropFirst().enumerated() {
                guard let png = render(frame, strokes: clipBlurs, lineWidth: 0) else { continue }
                let url = folder.appendingPathComponent("Capipaste \(stamp) frame \(i + 2).png")
                try png.write(to: url)
                text += "\n[clip frame \(i + 2): \(url.path)]"
            }
        }

        copy(pngs: pngs, urls: urls, text: text, textOnly: textOnly || !image)
        if let movie, !textOnly, image {
            let item = NSPasteboardItem()
            item.setString(movie.absoluteString, forType: .fileURL)
            NSPasteboard.general.writeObjects([item])
        }
        Recordings.save(audio, besides: History.save(text, besides: urls[0]))
        return urls
    }

    /// `2026-09-22 at 14.03.07`, like macOS names screenshots; ` 2`, ` 3`… when that second is taken already.
    static func stamp(in folder: URL, now: Date = Date()) -> String {
        let base = stamp(now)
        let taken = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .map { ($0 as NSString).deletingPathExtension }
        func free(_ name: String) -> Bool { !taken.contains { $0 == "Capipaste \(name)" || $0.hasPrefix("Capipaste \(name) ") } }
        if free(base) { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first(where: free)!
    }

    static func stamp(_ date: Date) -> String {
        date.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)", timeZone: .current, calendar: .current))
    }
}

extension Output {
    /// One pasteboard item per image; the note rides on the first.
    static func copy(pngs: [Data], urls: [URL], text: String, textOnly: Bool) {
        let many = pngs.count > 1
        let items = pngs.enumerated().map { i, png in
            let item = NSPasteboardItem()
            if !textOnly {
                if many { item.setString(urls[i].absoluteString, forType: .fileURL) }
                // PNG only: a TIFF copy is uncompressed (~60 MB for a 5K shot) and every app we paste into reads PNG.
                item.setData(png, forType: .png)
            }
            return item
        }
        let first = items.first ?? NSPasteboardItem()
        first.setString(text, forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(textOnly || items.isEmpty ? [first] : items)
    }

    /// Dictation: text only, no image. Saved to history (with its recording) like a capture.
    /// With `pasting`, the text goes up as a one-off paste and what you had copied comes back afterwards.
    @MainActor static func deliver(text: String, audio: [Float] = [], pasting: Bool = false) {
        if pasting {
            PasteSession.start(text) // pasted() is marked by paste()
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        let folder = AppModel.capturesFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let note = History.save(text, besides: folder.appendingPathComponent("Capipaste \(stamp(in: folder)).txt"))
        Recordings.save(audio, besides: note)
    }

    /// Presses ⌘V in whatever app is frontmost. Needs Accessibility.
    @MainActor static func paste() {
        guard AXIsProcessTrusted() else { return }
        // Private state: keys you're still holding (the ⌥ of a shortcut) don't merge into this ⌘V.
        // ⌘ down, V down, V up, ⌘ up, as a hand would: some apps ignore a V that arrives with ⌘ already gone.
        let source = CGEventSource(stateID: .privateState)
        let command: CGKeyCode = 55, v: CGKeyCode = 9
        let steps: [(CGKeyCode, Bool, CGEventFlags)] = [(command, true, .maskCommand), (v, true, .maskCommand),
                                                        (v, false, .maskCommand), (command, false, [])]
        for (key, down, flags) in steps {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
            usleep(8_000)
        }
        PasteSession.current?.pasted()
    }
}

/// A dictation paste that leaves your clipboard as it found it. The text is offered lazily, so we see the
/// target app actually read it (after our ⌘V); once reads go quiet, and only if nothing else has touched the
/// clipboard since, what you had copied is put back. Clipboard managers are told to skip the one-off text.
@MainActor
final class PasteSession: NSObject, NSPasteboardItemDataProvider {
    static private(set) var current: PasteSession?
    /// Swapped by the checks so they never touch your clipboard.
    static var board = NSPasteboard.general
    /// How long an unread paste waits before settling for leaving the text on the clipboard.
    static var giveUp: Double = 8

    private nonisolated let text: String
    private let saved: [NSPasteboardItem]
    private var changeCount = 0
    private var pastedAt: Date?
    private var restoreTask: Task<Void, Never>?

    private init(text: String) {
        self.text = text
        // Deep copy: the originals belong to the pasteboard and die with clearContents().
        saved = (Self.board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
    }

    static func start(_ text: String) {
        current?.finish(restore: false) // a newer paste wins; the older one's snapshot is already stale
        let session = PasteSession(text: text)
        let pasteboard = board
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setDataProvider(session, forTypes: [.string])
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pasteboard.writeObjects([item])
        session.changeCount = pasteboard.changeCount
        current = session
        // No ⌘V (no Accessibility) or nobody reads: keep the text on the clipboard, like before.
        session.schedule(after: giveUp, restore: false)
    }

    /// Our ⌘V went out; reads from now on are the paste.
    func pasted() { pastedAt = Date() }

    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(text, forType: type)
        Task { @MainActor in
            // ponytail: 250 ms of quiet after the last read (Chromium reads twice); a slow app that reads
            // later than that gets the restored clipboard, lengthen if one shows up
            if self.pastedAt != nil { self.schedule(after: 0.25, restore: true) }
        }
    }

    private func schedule(after seconds: Double, restore: Bool) {
        restoreTask?.cancel()
        restoreTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.finish(restore: restore)
        }
    }

    private func finish(restore: Bool) {
        restoreTask?.cancel()
        if Self.current === self { Self.current = nil }
        let pasteboard = Self.board
        // Someone copied something since: theirs wins.
        guard pasteboard.changeCount == changeCount else { return }
        if restore {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        } else {
            // Leaving the text in place: swap the lazy promise for the real string, so it survives us.
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    nonisolated func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}
