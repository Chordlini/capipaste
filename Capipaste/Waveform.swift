import SwiftUI

/// Mirrored dot-matrix meter in black: one column per level sample, newest on the right.
struct Waveform: View {
    let levels: [Float]
    let live: Bool

    private let dot: CGFloat = 3
    private let gap: CGFloat = 1.5
    private let rows = 5

    var body: some View {
        Canvas { ctx, size in
            // One column every 7pt, fed from the newest levels.
            let shown = Array(levels.suffix(max(Int(size.width / 7), 1)))
            let columnWidth = size.width / CGFloat(shown.count)
            var lit = Path()
            var faint = Path()
            for (column, level) in shown.enumerated() {
                let x = columnWidth * (CGFloat(column) + 0.5)
                let reach = live ? Int((Double(level) * Double(rows)).rounded()) : -1
                for row in -rows...rows {
                    let y = size.height / 2 + CGFloat(row) * (dot + gap)
                    let rect = CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)
                    if abs(row) <= reach || (live && row == 0) {
                        lit.addEllipse(in: rect)
                    } else {
                        faint.addEllipse(in: rect)
                    }
                }
            }
            ctx.fill(faint, with: .color(.black.opacity(live ? 0.1 : 0.07)))
            ctx.fill(lit, with: .color(.black.opacity(live ? 0.9 : 0.35)))
        }
        .accessibilityLabel(live ? "Listening" : "Microphone off")
    }
}
