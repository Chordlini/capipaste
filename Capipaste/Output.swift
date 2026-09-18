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

    /// The whole capture as a coarse mosaic; blur boxes show this through their clip.
    static func pixelated(_ cg: CGImage) -> CGImage? {
        let image = CIImage(cgImage: cg)
        let block = max(8, Double(cg.width) / 70) // ponytail: ~70 blocks across, unreadable at any capture size
        let mosaic = image.clampedToExtent().applyingFilter("CIPixellate", parameters: ["inputScale": block]).cropped(to: image.extent)
        return CIContext().createCGImage(mosaic, from: image.extent)
    }

    /// Saves the PNGs and puts image(s) + note on the clipboard. Returns the saved files.
    @discardableResult
    static func deliver(pngs: [Data], note: String, screenTexts: [String] = [], textOnly: Bool = false) throws -> [URL] {
        let folder = AppModel.capturesFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)", timeZone: .current, calendar: .current))
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
        for (i, screen) in screenTexts.enumerated() where !screen.isEmpty {
            text += "Text in the screenshot\(many ? " \(i + 1)" : ""):\n```text\n\(screen)\n```\n\n"
        }
        text += urls.enumerated().map { "[screenshot\(many ? " \($0.offset + 1)" : ""): \($0.element.path)]" }.joined(separator: "\n")

        copy(pngs: pngs, urls: urls, text: text, textOnly: textOnly)
        History.save(text, besides: urls[0])
        return urls
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
                item.setData(png, forType: .png)
                if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
            }
            return item
        }
        let first = items.first ?? NSPasteboardItem()
        first.setString(text, forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(textOnly || items.isEmpty ? [first] : items)
    }

    /// Dictation: text only, no image.
    static func deliver(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Presses ⌘V in whatever app is frontmost. Needs Accessibility.
    static func paste() {
        guard AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
