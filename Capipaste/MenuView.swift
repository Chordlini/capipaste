import KeyboardShortcuts
import SwiftUI

struct MenuView: View {
    @Environment(AppModel.self) private var app
    @Environment(STT.self) private var stt
    @Environment(Permissions.self) private var permissions
    @Environment(\.dismiss) private var dismiss
    @State private var recent: [History.Entry] = []
    @State private var player: NSSound?
    @State private var playing: URL?
    @AppStorage("pasteImage") private var pasteImage = true
    @AppStorage("context") private var context = true
    @AppStorage("ocrMode") private var ocrMode: OCR.Mode = .terminals

    /// One quick drop-down open at a time.
    /// `-menuopen mic|model|paste|recent` renders with that one open (testing).
    @State private var open: Drop? = hookArguments.firstIndex(of: "-menuopen")
        .flatMap { hookArguments.indices.contains($0 + 1) ? Drop(rawValue: hookArguments[$0 + 1]) : nil }
    enum Drop: String { case mic, model, paste, recent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !permissions.ready { divider; setup }
            divider
            action("Capture", keys: caps(.capture)) { app.capture() }
            action("Record clip", keys: caps(.clip)) { app.recordClip() }
            action("Dictate", keys: holdCaps) { app.startDictation() }

            divider
            drop(.mic, "Microphone", value: app.selectedMic?.name ?? "None found") { micList }
            drop(.model, "Speech model", value: stt.inUse.chip) { modelList }
            drop(.paste, "Paste includes", value: pasteSummary) { pasteList }
            if !recent.isEmpty {
                drop(.recent, "Recent notes", value: "\(recent.count)") { recentList }
            }
            if let problem = stt.problem ?? (stt.inUse.cloud != nil ? stt.cloudProblem : nil) {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            divider
            settingsKey(.general)
            HStack(spacing: 0) {
                small("Captures folder", systemImage: "folder") { app.openCapturesFolder() }
                Spacer()
                small("Quit", systemImage: "power") { NSApp.terminate(nil) }
            }
            .padding(.top, 4)
        }
        .font(.system(size: 13))
        .padding(6)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.snappy(duration: 0.18), value: open)
        .onAppear { app.refreshMics(); permissions.refresh(); recent = History.recent(5) }
        .onDisappear { player?.stop(); playing = nil }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            AcornMark().frame(height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("Capipaste").font(.system(size: 15, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(permissions.ready ? Color.glacier : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(permissions.ready ? "\(stt.inUse.chip) · \(micShortName)" : "Needs setup")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.top, 6).padding(.bottom, 4)
    }

    private var micShortName: String {
        (app.selectedMic?.name ?? "no mic").replacingOccurrences(of: " Microphone", with: " mic")
    }

    // MARK: Actions

    private func action(_ title: String, keys: [String], _ run: @escaping () -> Void) -> some View {
        row {
            dismiss()
            run()
        } label: {
            Text(title)
            Spacer()
            KeyCaps(keys: keys)
        }
    }

    /// `⇧⌘S` → ⇧ ⌘ S, one key per cap.
    private func caps(_ name: KeyboardShortcuts.Name) -> [String] {
        guard let text = KeyboardShortcuts.getShortcut(for: name)?.description else { return [] }
        let modifiers = text.prefix { "⌃⌥⇧⌘".contains($0) }.map(String.init)
        let key = String(text.dropFirst(modifiers.count))
        return modifiers + (key.isEmpty ? [] : [key])
    }

    private var holdCaps: [String] {
        switch app.pushToTalk.trigger {
        case .rightCommand: ["hold", "right ⌘"]
        case .leftCommand: ["hold", "left ⌘"]
        case .rightOption: ["hold", "right ⌥"]
        case .off: caps(.dictate)
        }
    }

    // MARK: Quick drop-downs

    private func drop(_ which: Drop, _ title: String, value: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            row { open = open == which ? nil : which } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(open == which ? 90 : 0))
                    .frame(width: 12)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer(minLength: 8)
                Text(value)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            .accessibilityValue(value)
            .accessibilityHint(open == which ? "Collapse" : "Show choices")
            if open == which {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .padding(.vertical, 3)
                    .background(.primary.opacity(0.045), in: .rect(cornerRadius: 8))
                    .padding(.horizontal, 4).padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var micList: some View {
        ForEach(app.mics) { mic in
            row { app.micUID = mic.uid; open = nil } label: {
                check(mic == app.selectedMic)
                Text(mic.name).lineLimit(1)
                Spacer()
                if mic.isBluetooth { Text("headset").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
        more("Mic settings…", tab: .speech)
    }

    @ViewBuilder
    private var modelList: some View {
        ForEach(SpeechModel.allCases.filter { stt.isReady($0) }) { model in
            row { stt.active = model; open = nil } label: {
                check(stt.inUse == model)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title).lineLimit(1)
                    Text(model.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if model.cloud != nil { Image(systemName: "cloud").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
        ForEach(SpeechModel.allCases.filter { stt.progress[$0] != nil }) { model in
            row {} label: {
                check(false)
                Text(model.title).lineLimit(1).foregroundStyle(.secondary)
                Spacer()
                Text((stt.progress[model] ?? 0).formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.glacier)
            }
        }
        more("More models & API keys…", tab: .speech)
    }

    private var pasteSummary: String {
        let on = [pasteImage ? "Image" : nil, context ? "Context" : nil, ocrMode != .never ? "Text" : nil].compactMap { $0 }
        return on.isEmpty ? "Words only" : on.joined(separator: " · ")
    }

    @ViewBuilder
    private var pasteList: some View {
        toggle("Image", $pasteImage)
        toggle("Context (app, window, URL)", $context)
        toggle("Screen text", Binding(get: { ocrMode != .never }, set: { ocrMode = $0 ? .terminals : .never }))
        Text("Your words always go.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.vertical, 3)
    }

    @ViewBuilder
    private var recentList: some View {
        ForEach(recent) { entry in
            row {
                dismiss()
                History.copy(entry, textOnly: false)
            } label: {
                Text(entry.title).lineLimit(1)
                Spacer()
                Text(entry.date, format: .relative(presentation: .named)).font(.system(size: 11)).foregroundStyle(.secondary)
                if let audio = entry.audio {
                    Button { play(audio) } label: {
                        Image(systemName: playing == audio ? "stop.fill" : "play.fill").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help(playing == audio ? "Stop" : "Play the recording")
                    .accessibilityLabel(playing == audio ? "Stop" : "Play the recording")
                }
            }
        }
        row {
            dismiss()
            app.pasteLast()
        } label: {
            Text("Paste last note").foregroundStyle(.secondary)
            Spacer()
            KeyCaps(keys: caps(.pasteLast))
        }
    }

    /// The way from a drop-down into Settings, where the full controls live.
    private func more(_ title: String, tab: SettingsView.Tab) -> some View {
        row {
            dismiss()
            app.openSettings(tab: tab)
        } label: {
            check(false)
            Text(title).foregroundStyle(Color.glacier)
            Spacer()
        }
    }

    // MARK: Footer

    /// Settings as a key you press, per the brand's keyboard language.
    private func settingsKey(_ tab: SettingsView.Tab) -> some View {
        Button {
            dismiss()
            app.openSettings(tab: tab)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape").font(.system(size: 12, weight: .medium))
                Text("Settings").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("models · mics · keys · shortcuts")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
            .contentShape(.rect)
        }
        .buttonStyle(KeyCapStyle())
        .padding(.horizontal, 4).padding(.top, 2)
    }

    private func small(_ title: String, systemImage: String, _ run: @escaping () -> Void) -> some View {
        MenuRow(action: run) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9).padding(.vertical, 3)
        }
        .fixedSize()
    }

    /// One recording at a time; clicking the playing one stops it.
    private func play(_ url: URL) {
        player?.stop()
        guard playing != url, let sound = NSSound(contentsOf: url, byReference: true) else { playing = nil; return }
        player = sound
        playing = url
        sound.play()
        // ponytail: polls instead of an NSSoundDelegate; fine for one button
        Task { @MainActor in
            while sound.isPlaying { try? await Task.sleep(for: .milliseconds(250)) }
            if playing == url { playing = nil }
        }
    }

    // MARK: Setup

    @ViewBuilder
    private var setup: some View {
        header("Setup · \(permissions.remaining) step\(permissions.remaining == 1 ? "" : "s") left")
        Text("macOS has to let Capipaste in before ⌘⇧S works.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.bottom, 6)
            .fixedSize(horizontal: false, vertical: true)

        ForEach(permissions.steps) { step in
            MenuRow(action: { permissions.request(step) }) {
                HStack(alignment: .top, spacing: 8) {
                    stepMark(step)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(step.id). \(step.title)")
                        Text(step.state == .granted ? "Allowed" : step.why)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if step.state != .granted {
                        Text(step.state == .denied ? "Open Settings" : "Allow")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.glacier)
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        if permissions.screenNeedsRestart && permissions.screen != .granted {
            row { permissions.relaunch() } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Reopen Capipaste")
                    Text("Screen Recording only applies after a restart")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
        row { permissions.refresh() } label: {
            Text("Check again").foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func stepMark(_ step: Permissions.Step) -> some View {
        Image(systemName: step.state == .granted ? "checkmark.circle.fill" : "circle.dashed")
            .font(.system(size: 12))
            .foregroundStyle(step.state == .granted ? Color.glacier : .secondary)
            .padding(.top, 1)
    }

    private func row(action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        MenuRow(action: action) { HStack(spacing: 8) { label() }.padding(.horizontal, 9).padding(.vertical, 4) }
    }

    private func toggle(_ title: String, _ on: Binding<Bool>) -> some View {
        row { on.wrappedValue.toggle() } label: {
            check(on.wrappedValue)
            Text(title)
            Spacer()
        }
    }

    private func check(_ on: Bool) -> some View {
        Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.glacier)
            .opacity(on ? 1 : 0)
            .frame(width: 12)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.top, 4).padding(.bottom, 2)
    }

    private var divider: some View {
        Divider().padding(.horizontal, 9).padding(.vertical, 5)
    }
}

/// Menu-style row: highlights in the accent colour on hover.
struct MenuRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .frame(minHeight: 24)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? Color.glacier : .clear, in: .rect(cornerRadius: 6))
                .foregroundStyle(hovering ? Color.white : .primary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Shortcut hint as key caps, one key per cap (brand §7).
struct KeyCaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 10, weight: .medium, design: key.count > 1 ? .default : .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4.5)
                    .frame(minWidth: 17, minHeight: 17)
                    // Each .background goes behind the last: the face first, then the key's edge under it.
                    .background(RoundedRectangle(cornerRadius: 4.5).fill(.background))
                    .background(RoundedRectangle(cornerRadius: 4.5).fill(.primary.opacity(0.28)).offset(y: 1.5))
                    .overlay(RoundedRectangle(cornerRadius: 4.5).strokeBorder(.primary.opacity(0.28), lineWidth: 1))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: " "))
    }
}

/// A raised key: an edge underneath that the key drops onto when pressed.
struct KeyCapStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let lift: CGFloat = configuration.isPressed ? 0 : hovering ? 1.5 : 3
        configuration.label
            .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Color.glacier.opacity(0.14) : Color.primary.opacity(0.04)))
            .background(RoundedRectangle(cornerRadius: 9).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.55), lineWidth: 1.5))
            .offset(y: 3 - lift)
            .background(RoundedRectangle(cornerRadius: 9).fill(.primary.opacity(0.55)).offset(y: 3)) // the edge
            .padding(.bottom, 3)
            .onHover { hovering = $0 }
            .animation(.snappy(duration: 0.1), value: configuration.isPressed)
    }
}
