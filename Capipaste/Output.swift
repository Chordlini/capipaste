import AppKit

struct Stroke {
    static let width: CGFloat = 4
    static let color = CGColor(srgbRed: 1, green: 0.231, blue: 0.361, alpha: 1) // #FF3B5C

    var points: [CGPoint]

    /// Smooth path through the points (midpoint quad curves), in card coordinates.
    func path(_ transform: CGAffineTransform = .identity) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first, transform: transform)
        if points.count == 1 {
            path.addLine(to: first, transform: transform)
            return path
        }
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            path.addQuadCurve(to: mid, control: points[i - 1], transform: transform)
        }
        path.addLine(to: points[points.count - 1], transform: transform)
        return path
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
        ctx.setStrokeColor(Stroke.color)
        ctx.setLineWidth(lineWidth * scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // Image points are top-left origin; bitmap is bottom-left.
        let flip = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: 0, ty: CGFloat(height))
        for stroke in strokes {
            ctx.addPath(stroke.path(flip))
            ctx.strokePath()
        }
        guard let flattened = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: flattened).representation(using: .png, properties: [:])
    }

    /// Saves the PNG and puts image + note on the clipboard. Returns the saved file.
    @discardableResult
    static func deliver(png: Data, note: String, textOnly: Bool = false) throws -> URL {
        let folder = AppModel.capturesFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)", timeZone: .current, calendar: .current))
        let url = folder.appendingPathComponent("Capipaste \(stamp).png")
        try png.write(to: url)

        // Text-only targets (terminals) still reach the image through the path.
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (trimmed.isEmpty ? "" : trimmed + "\n\n") + "[screenshot: \(url.path)]"

        let item = NSPasteboardItem()
        if !textOnly {
            item.setData(png, forType: .png)
            if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        }
        item.setString(text, forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        return url
    }
}
