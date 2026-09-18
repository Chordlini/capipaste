import KeyboardShortcuts
import SwiftUI

extension Color {
    static let glacier = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.239, green: 0.851, blue: 0.757, alpha: 1)  // #3DD9C1
            : NSColor(srgbRed: 0.039, green: 0.561, blue: 0.494, alpha: 1)  // #0A8F7E
    })
    static let ink = Color(cgColor: Stroke.color)
}

struct CardView: View {
    @Bindable var model: CardModel
    @FocusState private var focus: Field?
    @State private var eraserAt: CGPoint?

    private enum Field { case card, text }

    var body: some View {
        VStack(spacing: 0) {
            shot
            if model.shots.count > 1 { thumbnails.padding(.top, 10) }
            waveBox.padding(.top, 10)
            transcript
            footer
        }
        .padding(10)
        .frame(width: model.cardWidth + 20)
        .background(VisualEffect().clipShape(.rect(cornerRadius: 16)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.35), radius: 28, y: 14)
        .overlay { if model.copied { toast } }
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .card)
        .onKeyPress(action: cardKey)
        .onAppear { focus = .card }
        .onChange(of: model.stt.live) { _, live in model.liveChanged(live) }
        .onChange(of: model.text) { _, new in model.textChanged(new) }
        .background {
            Group {
                Button("Undo", action: model.undo).keyboardShortcut("z", modifiers: .command)
                Button("Zoom in") { model.zoomStep(1.5) }.keyboardShortcut("=", modifiers: .command)
                Button("Zoom out") { model.zoomStep(1 / 1.5) }.keyboardShortcut("-", modifiers: .command)
                Button("Actual size", action: model.resetZoom).keyboardShortcut("0", modifiers: .command)
            }
            .hidden()
        }
        .animation(.snappy(duration: 0.2), value: model.copied)
    }

    private func cardKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .return: model.submit(); return .handled
        case .escape: model.cancel(); return .handled
        case KeyEquivalent("d"): model.tool = .draw; return .handled
        case KeyEquivalent("e"): model.tool = .erase; return .handled
        case KeyEquivalent("a"): model.tool = .arrow; return .handled
        case KeyEquivalent("b"): model.tool = .box; return .handled
        case KeyEquivalent("x"): model.tool = .blur; return .handled
        default: return .ignored
        }
    }

    // Screenshot + strokes + tool pill
    private var shot: some View {
        Image(nsImage: model.image)
            .resizable()
            .interpolation(model.zoom > 2 ? .none : .high) // crisp pixels when zoomed in
            .frame(width: model.shotSize.width * model.zoom, height: model.shotSize.height * model.zoom)
            .offset(x: model.offset.x, y: model.offset.y)
            .frame(width: model.shotSize.width, height: model.shotSize.height, alignment: .topLeading)
            .overlay {
                Canvas { ctx, _ in
                    let style = StrokeStyle(lineWidth: Stroke.width * model.zoom, lineCap: .round, lineJoin: .round)
                    let transform = model.toView
                    let all = model.strokes + [model.current].compactMap({ $0 })
                    // Blur boxes show the mosaic through them, under the annotations.
                    if let mosaic = model.mosaic {
                        let frame = CGRect(x: model.offset.x, y: model.offset.y,
                                           width: model.shotSize.width * model.zoom, height: model.shotSize.height * model.zoom)
                        for blur in all where blur.kind == .blur {
                            ctx.drawLayer { layer in
                                layer.clip(to: Path(blur.path(transform)))
                                layer.draw(Image(nsImage: mosaic).interpolation(.none), in: frame)
                            }
                        }
                    }
                    for stroke in all where stroke.kind != .blur {
                        ctx.stroke(Path(stroke.path(transform, lineWidth: Stroke.width / model.fitScale)), with: .color(.ink), style: style)
                    }
                    if let blur = model.current, blur.kind == .blur {
                        ctx.stroke(Path(blur.path(transform)), with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    if let p = eraserAt, model.tool == .erase {
                        let ring = Path(ellipseIn: CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20))
                        ctx.fill(ring, with: .color(.white.opacity(0.35)))
                        ctx.stroke(ring, with: .color(.black.opacity(0.8)), lineWidth: 1.2)
                    }
                }
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { model.drag(to: $0.location); eraserAt = $0.location }
                    .onEnded { _ in model.endDrag() })
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { model.pinchChanged($0.magnification, at: $0.startLocation) }
                    .onEnded { _ in model.pinchEnded() })
                .onContinuousHover { phase in
                    if case let .active(p) = phase { eraserAt = p } else { eraserAt = nil }
                }
            }
            .clipShape(.rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.black.opacity(0.08)))
            .overlay(alignment: .topTrailing) { tools.padding(10) }
            .overlay(alignment: .topLeading) {
                if model.zoom > 1.01 {
                    Button(action: model.resetZoom) {
                        Text("\(Int((model.zoom * model.fitScale * 100).rounded()))%")
                            .font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9).frame(height: 24)
                            .background(Color(white: 0.08, opacity: 0.8), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .help("Reset zoom (⌘0)")
                    .padding(10)
                }
            }
            .frame(maxWidth: .infinity)
    }

    /// Every capture in this note; click to switch, × to drop one.
    private var thumbnails: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.shots.enumerated()), id: \.offset) { i, shot in
                    Button { model.select(i) } label: {
                        Image(nsImage: shot.image)
                            .resizable().scaledToFill()
                            .frame(width: 84, height: 52)
                            .clipShape(.rect(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(i == model.index ? Color.ink : .white.opacity(0.25), lineWidth: i == model.index ? 2 : 1))
                            .overlay(alignment: .bottomLeading) {
                                Text("\(i + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 5).background(.black.opacity(0.6), in: .capsule).padding(4)
                            }
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .topTrailing) {
                        Button { model.remove(i) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                                .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.7))
                        }
                        .buttonStyle(.plain).offset(x: 5, y: -5)
                        .help("Remove this screenshot")
                    }
                }
            }
            .padding(.top, 5).padding(.trailing, 5)
        }
        .frame(height: 62)
    }

    private var tools: some View {
        HStack(spacing: 2) {
            toolButton("pencil.tip", "Draw (D)", on: model.tool == .draw, fill: .ink, glyph: .white) { model.tool = .draw }
            toolButton("arrow.up.right", "Arrow (A)", on: model.tool == .arrow, fill: .ink, glyph: .white) { model.tool = .arrow }
            toolButton("rectangle", "Box (B)", on: model.tool == .box, fill: .ink, glyph: .white) { model.tool = .box }
            toolButton("checkerboard.rectangle", "Blur (X)", on: model.tool == .blur, fill: .white, glyph: .black) { model.tool = .blur }
            toolButton("eraser", "Erase (E)", on: model.tool == .erase, fill: .white, glyph: .black) { model.tool = .erase }
            toolButton("arrow.uturn.backward", "Undo (⌘Z)", on: false, fill: .clear, glyph: .white, action: model.undo)
                .opacity(model.canUndo ? 1 : 0.4)
        }
        .padding(3)
        .background(Color(white: 0.08, opacity: 0.8), in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }

    private func toolButton(_ symbol: String, _ help: String, on: Bool, fill: Color, glyph: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? glyph : Color(white: 0.82))
                .frame(width: 30, height: 30)
                .background(on ? fill : .clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // Timer, dot waveform, model chip
    private var waveBox: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Circle()
                    .fill(model.recording ? Color.ink : .secondary)
                    .frame(width: 8, height: 8)
                    .shadow(color: model.recording ? .ink.opacity(0.5) : .clear, radius: 3)
                TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
                    let seconds = Int(model.stoppedAfter ?? context.date.timeIntervalSince(model.startedAt))
                    Text(model.recording || model.stoppedAfter != nil ? String(format: "%d:%02d", seconds / 60, seconds % 60) : "–:––")
                        .monospacedDigit()
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.black.opacity(0.7))
            .frame(minWidth: 56, alignment: .leading)

            Waveform(levels: model.levels, live: model.recording)
                .frame(height: 46)

            Text(model.stt.inUse.chip)
                .font(.system(size: 11))
                .foregroundStyle(Color.glacier)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.glacier.opacity(0.14), in: .capsule)
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        // Light frosted well so the black dots read on dark glass too.
        .background(.white.opacity(0.78), in: .rect(cornerRadius: 10))
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 10))
        .environment(\.colorScheme, .light)
        .contentShape(.rect)
        .onTapGesture { model.tool = .draw } // "click the visualizer to draw"
        .help("Click to draw on the screenshot")
    }

    private var transcript: some View {
        TextField("", text: $model.text, prompt: Text(placeholder).foregroundStyle(promptColor), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.primary)
            .lineSpacing(2)
            .lineLimit(2...8)
            .focused($focus, equals: .text)
            .onKeyPress(keys: [.return, .escape]) { press in
                if press.key == .escape { model.cancel() }
                else if press.modifiers.contains(.shift) { model.text += "\n" }
                else { model.submit() }
                return .handled
            }
            .overlay(alignment: .topLeading) {
                if model.finishing {
                    Text(model.tidying ? "Tidying…" : model.text.isEmpty ? "Transcribing…" : model.text)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(VisualEffect())
                        .phaseAnimator([0.45, 1]) { view, opacity in view.opacity(opacity) }
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .frame(minHeight: 58, alignment: .top)
    }

    private var promptColor: Color {
        model.failure != nil ? .ink : Color.primary.opacity(0.55)
    }

    private var placeholder: String {
        if let failure = model.failure { return failure }
        if let problem = model.stt.problem { return problem }
        return model.recording ? "Speak or type what should change" : "Type what should change"
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if let failure = model.failure, !model.text.isEmpty {
                Text(failure).foregroundStyle(Color.ink).lineLimit(1)
            }
            Spacer()
            hint(KeyboardShortcuts.getShortcut(for: .capture)?.description ?? "⌘⇧S", "Add shot")
            hint("↩", "Copy")
            hint("⇧↩", "New line")
            hint("esc", "Cancel")
        }
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(.primary.opacity(0.7))
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.primary.opacity(0.05), in: .rect(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.1)))
            Text(label)
        }
    }

    private var toast: some View {
        Label("Copied image and text", systemImage: "checkmark")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .labelStyle(ToastLabel())
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color(white: 0.08, opacity: 0.88), in: .capsule)
            .shadow(color: .black.opacity(0.35), radius: 15, y: 8)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
    }
}

private struct ToastLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(Color(red: 0.239, green: 0.851, blue: 0.757))
            configuration.title
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
