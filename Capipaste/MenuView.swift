import KeyboardShortcuts
import SwiftUI

struct MenuView: View {
    @Environment(AppModel.self) private var app
    @Environment(STT.self) private var stt
    @Environment(Permissions.self) private var permissions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !permissions.ready { setup; divider }
            row {
                dismiss()
                app.capture()
            } label: {
                Text("Capture")
                Spacer()
                Text("⌘⇧S").foregroundStyle(.secondary)
            }
            row {
                dismiss()
                app.startDictation()
            } label: {
                Text("Dictate")
                Spacer()
                Text(app.pushToTalk.trigger == .off ? "" : app.pushToTalk.trigger.title.replacingOccurrences(of: "Hold ", with: "hold "))
                    .foregroundStyle(.secondary)
            }
            row { app.openCapturesFolder() } label: { Text("Open captures folder"); Spacer() }
            row {
                dismiss()
                app.openSettings()
            } label: {
                Text("Settings…")
                Spacer()
                Text("⌘,").foregroundStyle(.secondary)
            }

            divider
            header("Microphone")
            ForEach(app.mics) { mic in
                row { app.micUID = mic.uid } label: {
                    check(mic == app.selectedMic)
                    Text(mic.name).lineLimit(1)
                    Spacer()
                }
            }

            divider
            header("Speech model")
            ForEach(SpeechModel.allCases) { model in
                modelRow(model)
            }
            if let problem = stt.problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            divider
            row { NSApp.terminate(nil) } label: {
                Text("Quit Capipaste")
                Spacer()
                Text("⌘Q").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .padding(5)
        .frame(width: 330)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { app.refreshMics(); permissions.refresh() }
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

    @ViewBuilder
    private func modelRow(_ model: SpeechModel) -> some View {
        let ready = stt.isReady(model)
        row {
            if ready { stt.active = model } else { stt.download(model) }
        } label: {
            check(stt.active == model)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).lineLimit(1)
                Text(model == .apple && stt.inUse == .apple && stt.active != .apple
                     ? "In use until \(stt.active.chip) downloads" : model.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = stt.progress[model] {
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(Color.glacier)
            } else if !ready {
                Text(model.downloadHint)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.glacier)
            } else if let bytes = stt.diskSize[model] {
                Text(bytes.formatted(.byteCount(style: .file)))
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.secondary)
                Button { stt.delete(model) } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete \(model.title)")
            }
        }
        if let progress = stt.progress[model] {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.glacier)
                .controlSize(.mini)
                .padding(.leading, 29).padding(.trailing, 9).padding(.bottom, 4)
        }
    }

    private func row(action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        MenuRow(action: action) { HStack(spacing: 8) { label() }.padding(.horizontal, 9).padding(.vertical, 4) }
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
