// Capipaste artwork in one e-ink style: shapes are drawn in greyscale onto a coarse dot grid,
// Bayer-dithered to 1-bit, then printed as square ink dots on grey paper.
//
// usage:
//   swift design/make-art.swift icon   <out.png> [px]
//   swift design/make-art.swift banner <out.png> <width> <height> <title> <subtitle> [caption]
//   swift design/make-art.swift steps  <out.png> <width> <height>
import AppKit
import CoreText

let args = CommandLine.arguments
let mode = args[1]
let out = args[2]
let gray = CGColorSpaceCreateDeviceGray()
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let paper = CGColor(srgbRed: 0.878, green: 0.878, blue: 0.863, alpha: 1)   // #E0E0DC
let inkColor = CGColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1)   // #17171A

func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

// MARK: - Dot field

/// A greyscale canvas `cols × rows` dots, drawn in a y-down coordinate space.
final class Field {
    let cols: Int, rows: Int
    let ctx: CGContext

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        ctx = CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: cols,
                        space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: cols, height: rows))
        ctx.translateBy(x: 0, y: CGFloat(rows))
        ctx.scaleBy(x: 1, y: -1)
    }

    /// Paper tone darkening toward the edges so the border dithers into sparse dots.
    func vignette(strength: CGFloat = 0.2) {
        let g = CGGradient(colorSpace: gray, colorComponents: [1, 1, 1 - strength, 1] as [CGFloat], locations: [0.55, 1], count: 2)!
        let c = pt(CGFloat(cols) / 2, CGFloat(rows) / 2)
        ctx.saveGState()
        ctx.scaleBy(x: 1, y: CGFloat(rows) / CGFloat(cols)) // elliptical for wide fields
        ctx.drawRadialGradient(g, startCenter: pt(c.x, c.y * CGFloat(cols) / CGFloat(rows)), startRadius: 0,
                               endCenter: pt(c.x, c.y * CGFloat(cols) / CGFloat(rows)), endRadius: CGFloat(cols) * 0.72, options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// Runs `draw` with a 1000-unit design box mapped onto `rect` (field dots).
    func inBox(_ rect: CGRect, _ draw: (CGContext) -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / 1000, y: rect.height / 1000)
        draw(ctx)
        ctx.restoreGState()
    }

    /// Ordered 4×4 Bayer dither → which dots get ink (row 0 = top).
    func dither() -> [[Bool]] {
        let bayer: [[Double]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<rows).map { y in
            (0..<cols).map { x in Double(data[y * cols + x]) / 255 < (bayer[y % 4][x % 4] + 0.5) / 16 }
        }
    }
}

func clipped(_ c: CGContext, _ path: CGPath, _ draw: () -> Void) {
    c.saveGState()
    c.addPath(path)
    c.clip()
    draw()
    c.restoreGState()
}

func grad(_ stops: [CGFloat]) -> CGGradient {
    // stops: grey values evenly spaced
    let comps: [CGFloat] = stops.flatMap { [$0, CGFloat(1)] }
    let locs = stops.indices.map { CGFloat($0) / CGFloat(max(stops.count - 1, 1)) }
    return CGGradient(colorSpace: gray, colorComponents: comps, locations: locs, count: stops.count)!
}

// MARK: - Acorn (1000-unit box)

func drawAcorn(_ c: CGContext) {
    let nut = CGMutablePath()
    nut.move(to: pt(272, 468))
    nut.addCurve(to: pt(500, 845), control1: pt(258, 720), control2: pt(380, 845))
    nut.addCurve(to: pt(728, 468), control1: pt(620, 845), control2: pt(742, 720))
    nut.closeSubpath()

    let cap = CGMutablePath()
    cap.move(to: pt(232, 488))
    cap.addCurve(to: pt(500, 285), control1: pt(205, 335), control2: pt(355, 285))
    cap.addCurve(to: pt(768, 488), control1: pt(645, 285), control2: pt(795, 335))
    cap.addCurve(to: pt(232, 488), control1: pt(650, 535), control2: pt(350, 535))
    cap.closeSubpath()

    let stem = CGMutablePath()
    stem.move(to: pt(500, 300))
    stem.addCurve(to: pt(530, 225), control1: pt(498, 270), control2: pt(510, 240))

    let leaf = CGMutablePath()
    leaf.move(to: pt(520, 240))
    leaf.addCurve(to: pt(705, 205), control1: pt(560, 150), control2: pt(670, 140))
    leaf.addCurve(to: pt(520, 240), control1: pt(700, 290), control2: pt(580, 310))
    leaf.closeSubpath()

    clipped(c, nut) {
        c.drawRadialGradient(grad([0.97, 0.86, 0.55]), startCenter: pt(420, 580), startRadius: 20,
                             endCenter: pt(480, 640), endRadius: 320, options: [.drawsAfterEndLocation])
        c.setStrokeColor(gray: 1, alpha: 1)
        c.setLineWidth(22)
        c.setLineCap(.round)
        c.move(to: pt(320, 560)); c.addCurve(to: pt(365, 720), control1: pt(310, 620), control2: pt(330, 680))
        c.strokePath()
    }
    c.addPath(nut)
    c.setStrokeColor(gray: 0, alpha: 1)
    c.setLineWidth(20)
    c.strokePath()
    c.setFillColor(gray: 0.05, alpha: 1)
    c.fillEllipse(in: CGRect(x: 486, y: 832, width: 28, height: 26))

    for x in [410.0, 590.0] {
        c.setFillColor(gray: 0, alpha: 1)
        c.fillEllipse(in: CGRect(x: x - 30, y: 605, width: 60, height: 70))
        c.setFillColor(gray: 1, alpha: 1)
        c.fillEllipse(in: CGRect(x: x - 16, y: 616, width: 22, height: 22))
        c.setFillColor(gray: 0.7, alpha: 1)
        c.fillEllipse(in: CGRect(x: x + (x < 500 ? -62 : 22), y: 690, width: 40, height: 24))
    }
    c.setStrokeColor(gray: 0, alpha: 1)
    c.setLineWidth(14)
    c.setLineCap(.round)
    c.move(to: pt(470, 698)); c.addQuadCurve(to: pt(530, 698), control: pt(500, 730))
    c.strokePath()

    clipped(c, cap) {
        c.drawLinearGradient(grad([0.38, 0.04]), start: pt(320, 300), end: pt(700, 520), options: [])
        c.setStrokeColor(gray: 0.88, alpha: 1)
        c.setLineWidth(11)
        for offset in stride(from: -600.0, through: 1200, by: 84) {
            c.move(to: pt(offset, 250)); c.addLine(to: pt(offset + 300, 550))
            c.move(to: pt(offset + 300, 250)); c.addLine(to: pt(offset, 550))
        }
        c.strokePath()
    }
    c.setStrokeColor(gray: 0, alpha: 1)
    c.setLineWidth(16)
    c.move(to: pt(245, 490))
    c.addCurve(to: pt(755, 490), control1: pt(360, 535), control2: pt(640, 535))
    c.strokePath()

    c.setFillColor(gray: 0.05, alpha: 1)
    c.addPath(stem.copy(strokingWithWidth: 48, lineCap: .round, lineJoin: .round, miterLimit: 4))
    c.fillPath()
    clipped(c, leaf) {
        c.drawLinearGradient(grad([0.12, 0.5]), start: pt(530, 240), end: pt(705, 205), options: [])
        c.setStrokeColor(gray: 1, alpha: 1)
        c.setLineWidth(10)
        c.move(to: pt(535, 238)); c.addCurve(to: pt(690, 208), control1: pt(590, 212), control2: pt(640, 205))
        c.strokePath()
    }
}

// MARK: - Step pictograms (1000-unit box)

func drawCapture(_ c: CGContext) {
    // Screen with a dashed selection and corner brackets
    c.setStrokeColor(gray: 0, alpha: 1)
    c.setLineWidth(40)
    c.setLineCap(.round)
    c.setLineJoin(.round)
    for (a, b, d) in [(pt(200, 330), pt(200, 200), pt(330, 200)), (pt(670, 200), pt(800, 200), pt(800, 330)),
                      (pt(800, 670), pt(800, 800), pt(670, 800)), (pt(330, 800), pt(200, 800), pt(200, 670))] {
        c.move(to: a); c.addLine(to: b); c.addLine(to: d)
    }
    c.strokePath()
    // shaded selected region inside the brackets
    clipped(c, CGPath(rect: CGRect(x: 280, y: 280, width: 440, height: 440), transform: nil)) {
        c.drawLinearGradient(grad([0.45, 0.85]), start: pt(280, 280), end: pt(720, 720), options: [])
    }
    // cursor
    let cursor = CGMutablePath()
    cursor.move(to: pt(600, 560)); cursor.addLine(to: pt(600, 860)); cursor.addLine(to: pt(670, 790))
    cursor.addLine(to: pt(720, 890)); cursor.addLine(to: pt(760, 870)); cursor.addLine(to: pt(710, 770))
    cursor.addLine(to: pt(800, 770)); cursor.closeSubpath()
    c.setFillColor(gray: 0, alpha: 1)
    c.addPath(cursor); c.fillPath()
    c.setStrokeColor(gray: 1, alpha: 1); c.setLineWidth(14)
    c.addPath(cursor); c.strokePath()
}

func drawSpeak(_ c: CGContext) {
    // Mirrored level bars, chunky enough to survive the coarse dot grid
    let heights: [CGFloat] = [120, 260, 420, 300, 560, 380, 480, 220, 140]
    for (i, height) in heights.enumerated() {
        let x = 110 + CGFloat(i) * 92
        c.setFillColor(gray: 0, alpha: 1)
        c.fill(CGRect(x: x, y: 500 - height / 2, width: 56, height: height))
    }
}

func drawPaste(_ c: CGContext) {
    // Clipboard holding a picture and lines of text
    let board = CGPath(roundedRect: CGRect(x: 250, y: 190, width: 500, height: 640), cornerWidth: 60, cornerHeight: 60, transform: nil)
    clipped(c, board) { c.drawLinearGradient(grad([0.8, 0.95]), start: pt(250, 190), end: pt(750, 830), options: []) }
    c.addPath(board)
    c.setStrokeColor(gray: 0, alpha: 1); c.setLineWidth(36); c.strokePath()
    c.setFillColor(gray: 0, alpha: 1)
    c.addPath(CGPath(roundedRect: CGRect(x: 390, y: 140, width: 220, height: 110), cornerWidth: 30, cornerHeight: 30, transform: nil))
    c.fillPath()
    // picture
    let pic = CGRect(x: 330, y: 320, width: 340, height: 220)
    c.setFillColor(gray: 0.55, alpha: 1); c.fill(pic)
    c.setFillColor(gray: 0, alpha: 1)
    let hill = CGMutablePath()
    hill.move(to: pt(330, 540)); hill.addLine(to: pt(440, 420)); hill.addLine(to: pt(520, 500))
    hill.addLine(to: pt(580, 450)); hill.addLine(to: pt(670, 540)); hill.closeSubpath()
    c.addPath(hill); c.fillPath()
    c.setFillColor(gray: 1, alpha: 1); c.fillEllipse(in: CGRect(x: 580, y: 350, width: 50, height: 50))
    // text lines
    c.setStrokeColor(gray: 0, alpha: 1); c.setLineWidth(30); c.setLineCap(.round)
    for (y, w) in [(620.0, 320.0), (690.0, 260.0), (760.0, 200.0)] {
        c.move(to: pt(345, y)); c.addLine(to: pt(345 + w, y))
    }
    c.strokePath()
}

// MARK: - Text into the field (dithered)

func drawTitle(_ c: CGContext, _ text: String, at origin: CGPoint, height: CGFloat) {
    let font = CTFontCreateWithName("AvenirNext-Heavy" as CFString, height, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    c.saveGState()
    // field space is y-down; flip locally so the glyphs stand upright
    c.translateBy(x: origin.x - bounds.minX, y: origin.y + bounds.maxY)
    c.scaleBy(x: 1, y: -1)
    c.textMatrix = .identity
    c.textPosition = .zero
    c.setTextDrawingMode(.clip)
    CTLineDraw(line, c)
    c.drawLinearGradient(grad([0.0, 0.0, 0.45]), start: pt(0, bounds.maxY), end: pt(0, bounds.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
}

func titleWidth(_ text: String, height: CGFloat) -> CGFloat {
    let font = CTFontCreateWithName("AvenirNext-Heavy" as CFString, height, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
    return CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).width
}

// MARK: - Printing dots onto paper

func print(_ dots: [[Bool]], into ctx: CGContext, rect: CGRect, pitch: CGFloat) {
    let dot = pitch * 0.86
    ctx.setFillColor(inkColor)
    for (y, row) in dots.enumerated() {
        for (x, on) in row.enumerated() where on {
            ctx.addRect(CGRect(x: rect.minX + CGFloat(x) * pitch + (pitch - dot) / 2,
                               y: rect.maxY - CGFloat(y + 1) * pitch + (pitch - dot) / 2, width: dot, height: dot))
        }
    }
    ctx.fillPath()
}

func canvas(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func sheen(_ ctx: CGContext, _ rect: CGRect) {
    let g = CGGradient(colorsSpace: sRGB, colors: [CGColor(gray: 1, alpha: 0.35), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: pt(rect.minX, rect.maxY), end: pt(rect.midX, rect.midY), options: [])
}

/// Crisp mono caption in ink, drawn directly (not dithered) so it stays readable.
func caption(_ ctx: CGContext, _ text: String, x: CGFloat, baseline: CGFloat, size: CGFloat, alpha: CGFloat = 1) {
    let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): inkColor.copy(alpha: alpha)!,
        NSAttributedString.Key(kCTKernAttributeName as String): size * 0.02,
    ]))
    ctx.textPosition = pt(x, baseline)
    CTLineDraw(line, ctx)
}

func save(_ ctx: CGContext) {
    try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: out))
}

// MARK: - Modes

switch mode {
case "icon":
    let px = args.count > 3 ? Int(args[3])! : 1024
    let grid = 112
    let field = Field(cols: grid, rows: grid)
    field.vignette()
    field.inBox(CGRect(x: 0, y: -1.1, width: CGFloat(grid), height: CGFloat(grid)), drawAcorn)
    let dots = field.dither()

    let ctx = canvas(px, px)
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(squircle); ctx.setFillColor(paper); ctx.fillPath()
    ctx.restoreGState()
    clipped(ctx, squircle) {
        sheen(ctx, body)
        print(dots, into: ctx, rect: body, pitch: 824 / CGFloat(grid))
    }
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.12)); ctx.setLineWidth(4); ctx.strokePath()
    save(ctx)

case "banner":
    let (w, h) = (Int(args[3])!, Int(args[4])!)
    let title = args[5], subtitle = args[6]
    let captionText = args.count > 7 ? args[7] : nil
    let pitch: CGFloat = 7
    let (cols, rows) = (Int(CGFloat(w) / pitch), Int(CGFloat(h) / pitch))
    let field = Field(cols: cols, rows: rows)
    field.vignette(strength: 0.18)

    // acorn on the left, wordmark to its right, block centred horizontally
    let art = CGFloat(rows) * 0.78
    let gapDots = CGFloat(rows) * 0.06
    // Title as tall as 26% of the banner, shrunk if the block would overflow 88% of the width.
    let wanted = CGFloat(rows) * 0.26
    let room = CGFloat(cols) * 0.88 - art - gapDots
    let titleHeight = min(wanted, wanted * room / titleWidth(title, height: wanted))
    let blockWidth = art + gapDots + titleWidth(title, height: titleHeight)
    let left = (CGFloat(cols) - blockWidth) / 2
    field.inBox(CGRect(x: left, y: (CGFloat(rows) - art) / 2 - 1, width: art, height: art), drawAcorn)
    let titleTop = CGFloat(rows) * 0.30
    drawTitle(field.ctx, title, at: pt(left + art + gapDots, titleTop), height: titleHeight)
    let dots = field.dither()

    let ctx = canvas(w, h)
    let rect = CGRect(x: 0, y: 0, width: w, height: h)
    ctx.setFillColor(paper); ctx.fill(rect)
    sheen(ctx, rect)
    print(dots, into: ctx, rect: CGRect(x: (CGFloat(w) - CGFloat(cols) * pitch) / 2, y: (CGFloat(h) - CGFloat(rows) * pitch) / 2,
                                        width: CGFloat(cols) * pitch, height: CGFloat(rows) * pitch), pitch: pitch)
    let textX = (CGFloat(w) - CGFloat(cols) * pitch) / 2 + (left + art + gapDots) * pitch
    let titleBottomY = CGFloat(h) - (titleTop + titleHeight) * pitch
    let size = CGFloat(h) * 0.045
    caption(ctx, subtitle, x: textX + 4, baseline: titleBottomY - size * 2.0, size: size)
    if let captionText { caption(ctx, captionText, x: textX + 4, baseline: titleBottomY - size * 3.7, size: size * 0.8, alpha: 0.6) }
    save(ctx)

case "steps":
    let (w, h) = (Int(args[3])!, Int(args[4])!)
    let pitch: CGFloat = 6
    let ctx = canvas(w, h)
    let rect = CGRect(x: 0, y: 0, width: w, height: h)
    ctx.setFillColor(paper); ctx.fill(rect)
    sheen(ctx, rect)
    let steps: [(String, String, (CGContext) -> Void)] = [
        ("1  ⌘⇧S", "drag to capture", drawCapture),
        ("2  talk", "or type the change", drawSpeak),
        ("3  ↩", "image + note copied", drawPaste),
    ]
    let panel = CGFloat(w) / 3
    let art = min(panel * 0.62, CGFloat(h) * 0.62)
    for (i, step) in steps.enumerated() {
        let n = Int(art / pitch)
        let field = Field(cols: n, rows: n)
        field.ctx.setShouldAntialias(false) // crisp 1-bit pictograms
        field.inBox(CGRect(x: 0, y: 0, width: CGFloat(n), height: CGFloat(n)), step.2)
        let x = CGFloat(i) * panel + (panel - art) / 2
        let top = CGFloat(h) * 0.08
        print(field.dither(), into: ctx, rect: CGRect(x: x, y: CGFloat(h) - top - art, width: CGFloat(n) * pitch, height: CGFloat(n) * pitch), pitch: pitch)
        let size = CGFloat(h) * 0.07
        caption(ctx, step.0, x: x, baseline: CGFloat(h) - top - art - size * 1.8, size: size)
        caption(ctx, step.1, x: x, baseline: CGFloat(h) - top - art - size * 3.1, size: size * 0.7, alpha: 0.6)
        if i > 0 {
            // dotted divider
            ctx.setFillColor(inkColor.copy(alpha: 0.35)!)
            for y in stride(from: CGFloat(h) * 0.12, to: CGFloat(h) * 0.88, by: 12) {
                ctx.fill(CGRect(x: CGFloat(i) * panel - 2, y: y, width: 4, height: 4))
            }
        }
    }
    save(ctx)

default:
    fatalError("unknown mode \(mode)")
}
