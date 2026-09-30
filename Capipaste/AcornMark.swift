import SwiftUI

/// The dithered acorn, drawn from the brand dot map (brand/assets/acorn-dots-56.json) as square ink dots
/// snapped to whole device pixels: a scaled-down PNG aliases and the face falls apart at menu sizes.
struct AcornMark: View {
    static let rows = [
        "000000000000000000000010000000",
        "000000000000000000010111010000",
        "000000000000000010101000100000",
        "000000000000000111010101110000",
        "000000000000001010101010100000",
        "000000000000001111111111000000",
        "000000000000001110001010000000",
        "000000010101011111010100000000",
        "000000100010101010001010000000",
        "000001110101010101011101010000",
        "000010001000101010101011101000",
        "000111011101110101110111011100",
        "001000100010001010101010111010",
        "001101110111011111011101111101",
        "001010101010101010101010101010",
        "110111011101111101110111111110",
        "001010101010101000101010001000",
        "010101110111010111011101111100",
        "111010101010101110001010111010",
        "011111111101110111111111111110",
        "001000001010101010101010000010",
        "011001000000000001000100010100",
        "001000000000000000000000000110",
        "011100010000000100010001010100",
        "001000000000000000000000001100",
        "001100000110000000011100011100",
        "001100001010000000101000001100",
        "000100010111000100011101011100",
        "000100000010000000001000001000",
        "000110000000010001000100011000",
        "000010000000001010000000111000",
        "000011000001000100010101110000",
        "000001100000000000000000100000",
        "000001100100010001000101100000",
        "000000110000000000000011000000",
        "000000011101010101010111000000",
        "000000001110000000001100000000",
        "000000000111111101110000000000",
        "000000000000111110100000000000",
    ]
    @Environment(\.displayScale) private var scale

    var body: some View {
        Canvas { ctx, size in
            let cols = Self.rows[0].count, count = Self.rows.count
            // Whole device pixels per dot, then a ~14% gap like the engine's print.
            let pitch = max(1, (min(size.width / CGFloat(cols), size.height / CGFloat(count)) * scale).rounded(.down)) / scale
            let dot = max(1 / scale, ((pitch * 0.86) * scale).rounded() / scale)
            let x0 = ((size.width - pitch * CGFloat(cols)) / 2 * scale).rounded() / scale
            let y0 = ((size.height - pitch * CGFloat(count)) / 2 * scale).rounded() / scale
            var ink = Path()
            for (r, row) in Self.rows.enumerated() {
                for (c, cell) in row.enumerated() where cell == "1" {
                    ink.addRect(CGRect(x: x0 + CGFloat(c) * pitch, y: y0 + CGFloat(r) * pitch, width: dot, height: dot))
                }
            }
            ctx.fill(ink, with: .style(.primary))
        }
        .aspectRatio(30.0 / 39.0, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
