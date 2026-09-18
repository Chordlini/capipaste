import KeyboardShortcuts
import ServiceManagement
import SwiftUI

/// A plain window we own — the SwiftUI `Settings` scene doesn't open reliably from a
/// menu-bar-only app.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(_ content: some View) {
        if window == nil {
            let hosting = NSHostingView(rootView: AnyView(content))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Capipaste Settings"
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "keyboard") }
            SpeechSettings().tabItem { Label("Speech", systemImage: "waveform") }
            PermissionSettings().tabItem { Label("Permissions", systemImage: "lock.shield") }
            UpdateSettings().tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(Permissions.self) private var permissions
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("ocrMode") private var ocrMode: OCR.Mode = .terminals

    var body: some View {
        Form {
            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Capture a screenshot", name: .capture)
                KeyboardShortcuts.Recorder("Dictate (tap shortcut)", name: .dictate)
            }
            Section("Hold to talk") {
                Picker("Hold", selection: Binding(
                    get: { app.pushToTalk.trigger },
                    set: { app.pushToTalk.trigger = $0 })) {
                    ForEach(PushToTalk.Trigger.allCases) { Text($0.title).tag($0) }
                }
                Text("Hold the key, say what you want, let go. The text lands on the clipboard\(permissions.canDictateHandsFree ? " and pastes where you were." : ". Grant Accessibility to have it paste for you.")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Screenshot text") {
                Picker("Include the text in the screenshot", selection: $ocrMode) {
                    ForEach(OCR.Mode.allCases) { Text($0.title).tag($0) }
                }
                Text("Read on your Mac and pasted under your note. Terminals only get text, so this is how they see what was on screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Open Capipaste at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Speech

private struct SpeechSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(STT.self) private var stt
    @AppStorage("vocabulary") private var vocabulary = ""

    var body: some View {
        Form {
            Section("Microphone") {
                Picker("Input", selection: Binding(
                    get: { app.selectedMic?.uid ?? "" },
                    set: { app.micUID = $0 })) {
                    ForEach(app.mics) { Text($0.name).tag($0.uid) }
                }
                .onAppear { app.refreshMics() }
            }
            Section("Model") {
                ForEach(SpeechModel.allCases) { model in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: stt.active == model ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(stt.active == model ? Color.glacier : .secondary)
                            .onTapGesture { if stt.isReady(model) { stt.active = model } }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.title)
                            Text(model.subtitle).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let progress = stt.progress[model] {
                            ProgressView(value: progress).frame(width: 90)
                        } else if !stt.isReady(model) {
                            Button("Download") { stt.download(model) }
                        } else if let bytes = stt.diskSize[model] {
                            Text(bytes.formatted(.byteCount(style: .file)))
                                .font(.callout).foregroundStyle(.secondary)
                            Button(role: .destructive) { stt.delete(model) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                if let problem = stt.problem {
                    Text(problem).font(.callout).foregroundStyle(Color.ink)
                }
            }
            Section("Vocabulary") {
                TextEditor(text: $vocabulary)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(height: 90)
                Text("One per line. A word like `useEffect` or `Supabase` fixes its spelling and helps Nemotron hear it; `super base = Supabase` replaces a mishearing. Names in your screenshot are added for that capture automatically.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TidySettings(tidy: app.tidy)
        }
        .formStyle(.grouped)
    }
}

private struct TidySettings: View {
    @Bindable var tidy: Tidy

    var body: some View {
        Section("Tidy") {
            Toggle("Tidy spoken notes before pasting", isOn: $tidy.enabled)
            Text("Drops the ums and false starts and turns what you said into one clear instruction. Runs on your Mac. \(tidy.status)")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local model: Qwen 3.5 2B")
                    Text("1.7 GB. Only used when Apple Intelligence is off.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let progress = tidy.progress {
                    ProgressView(value: progress).frame(width: 90)
                } else if tidy.localReady {
                    Button(role: .destructive) { tidy.deleteLocal() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                } else {
                    Button("Download") { tidy.downloadLocal() }
                }
            }
            if let problem = tidy.problem {
                Text(problem).font(.callout).foregroundStyle(Color.ink)
            }
        }
    }
}

// MARK: - Permissions

private struct PermissionSettings: View {
    @Environment(Permissions.self) private var permissions

    var body: some View {
        Form {
            Section("macOS has to let Capipaste in") {
                ForEach(permissions.steps) { step in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: step.state == .granted ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(step.state == .granted ? Color.glacier : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                            Text(step.state == .granted ? "Allowed" : step.why)
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if step.state != .granted {
                            Button(step.state == .denied ? "Open Settings" : "Allow") { permissions.request(step) }
                        }
                    }
                }
            }
            Section {
                Button("Check again") { permissions.refresh() }
                if permissions.screenNeedsRestart && permissions.screen != .granted {
                    Button("Reopen Capipaste") { permissions.relaunch() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
    }
}

// MARK: - Updates

private struct UpdateSettings: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        Form {
            Section {
                LabeledContent("This copy", value: updater.currentVersion)
                HStack {
                    Button("Check now") { Task { await updater.check() } }
                    Spacer()
                    status
                }
                if case .available = updater.status, let release = updater.release {
                    HStack {
                        Link("Release notes", destination: release.page)
                        Spacer()
                        if release.zip != nil {
                            Button("Install now") { Task { await updater.install() } }
                        }
                    }
                }
                if updater.status == .readyToRelaunch {
                    Button("Relaunch to finish") { Permissions().relaunch() }
                }
            }
            Section("Automatically") {
                Toggle("Check when Capipaste starts", isOn: Binding(
                    get: { updater.checkOnLaunch }, set: { updater.checkOnLaunch = $0 }))
                Toggle("Install updates by itself", isOn: Binding(
                    get: { updater.installAutomatically }, set: { updater.installAutomatically = $0 }))
                Text("Automatic installs only accept builds signed with the same identity as this copy.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var status: some View {
        switch updater.status {
        case .idle: Text(updater.lastChecked == nil ? "" : "Checked").foregroundStyle(.secondary)
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Label("Up to date", systemImage: "checkmark").foregroundStyle(.secondary)
        case let .available(version): Text("Version \(version) available").foregroundStyle(Color.glacier)
        case let .downloading(fraction): ProgressView(value: fraction).frame(width: 90)
        case .readyToRelaunch: Text("Installed").foregroundStyle(Color.glacier)
        case let .failed(message): Text(message).foregroundStyle(Color.ink).lineLimit(2)
        }
    }
}
