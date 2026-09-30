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
        // A fresh view each time, so a requested tab is the one that shows.
        window?.contentView = NSHostingView(rootView: AnyView(content))
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
    enum Tab { case general, speech, cloud, permissions, updates }
    @State var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "keyboard") }.tag(Tab.general)
            SpeechSettings().tabItem { Label("Speech", systemImage: "waveform") }.tag(Tab.speech)
            CloudSettings().tabItem { Label("Cloud", systemImage: "key") }.tag(Tab.cloud)
            PermissionSettings().tabItem { Label("Permissions", systemImage: "lock.shield") }.tag(Tab.permissions)
            UpdateSettings().tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag(Tab.updates)
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
    @AppStorage("context") private var context = true

    var body: some View {
        Form {
            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Capture a screenshot", name: .capture)
                KeyboardShortcuts.Recorder("Record a clip", name: .clip)
                KeyboardShortcuts.Recorder("Dictate (tap shortcut)", name: .dictate)
                KeyboardShortcuts.Recorder("Paste the last note again", name: .pasteLast)
            }
            Section("Hold to talk") {
                Picker("Hold", selection: Binding(
                    get: { app.pushToTalk.trigger },
                    set: { app.pushToTalk.trigger = $0 })) {
                    ForEach(PushToTalk.Trigger.allCases) { Text($0.title).tag($0) }
                }
                Text(permissions.canDictateHandsFree
                     ? "Hold the key, say what you want, let go: it pastes where you were, and whatever you had copied is put back. ⌃⌘V pastes it again."
                     : "Hold the key, say what you want, let go: the text lands on the clipboard. Grant Accessibility to have it paste for you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Context") {
                Toggle("Add the app, window title and page URL to the note", isOn: $context)
                Text("So the agent knows where you were. The page URL works in Safari, Chrome, Arc, Brave and Edge; macOS asks once per browser.")
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
    @AppStorage("keepRecordings") private var keepRecordings = Recordings.Keep.week.rawValue
    @AppStorage("avoidBluetoothMic") private var avoidBluetoothMic = true

    var body: some View {
        Form {
            Section("Microphone") {
                Picker("Input", selection: Binding(
                    get: { app.selectedMic?.uid ?? "" },
                    set: { app.micUID = $0 })) {
                    ForEach(app.mics) { Text($0.name).tag($0.uid) }
                }
                .onAppear { app.refreshMics() }
                Toggle("Use the built-in mic instead of AirPods and other Bluetooth headsets", isOn: $avoidBluetoothMic)
                Text("Opening a headset's mic drops what you're listening to into low-quality call mode. Applies when you haven't picked a mic above; noise suppression only runs on the system's default mic.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Recordings") {
                Picker("Keep voice recordings", selection: $keepRecordings) {
                    ForEach(Recordings.Keep.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: keepRecordings) { Task.detached { Recordings.prune() } }
                Text(keepRecordings == 0
                     ? "Nothing you say is saved. Older recordings are deleted."
                     : "Saved as .m4a next to each note in the captures folder; play them from the menu. Older ones are deleted automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                        } else if !stt.isReady(model), model.cloud != nil {
                            Text("Add a key under Cloud").font(.callout).foregroundStyle(.secondary)
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
                if let problem = stt.problem ?? stt.cloudProblem {
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

// MARK: - Cloud

private struct CloudSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(STT.self) private var stt

    var body: some View {
        Form {
            Section {
                Text("Optional. Capipaste runs entirely on your Mac until you add a key here and pick that provider. Then it receives, billed to your account: for speech, your recording plus names read off the screenshot as spelling hints; for tidy, your note plus the screenshot's text. Anything under a blur box is never sent. Live text while you talk still comes from your Mac, and if the provider can't be reached the on-device model finishes the note.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Cloud.Provider.allCases) { provider in
                KeyRow(provider: provider) { stt.keysChanged() }
            }
            Section("Use it for") {
                Picker("Speech", selection: Binding(
                    get: { stt.active.cloud == nil ? nil : stt.active },
                    set: { if let model = $0 { stt.active = model } else if stt.active.cloud != nil { stt.active = stt.local } })) {
                    Text("On this Mac").tag(SpeechModel?.none)
                    ForEach(SpeechModel.allCases.filter { $0.cloud != nil }) { model in
                        Text(model.chip).tag(Optional(model)).disabled(!stt.isReady(model))
                    }
                }
                Picker("Tidy", selection: Binding(get: { app.tidy.cloud }, set: { app.tidy.cloud = $0 })) {
                    Text("On this Mac").tag(Cloud.Provider?.none)
                    ForEach(Cloud.Provider.allCases) { provider in
                        Text(provider.title).tag(Optional(provider)).disabled(!stt.keys.contains(provider))
                    }
                }
                if let problem = stt.cloudProblem {
                    Text(problem).font(.callout).foregroundStyle(Color.ink)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Paste, check and save one provider's key. The key itself is never shown again once saved.
private struct KeyRow: View {
    let provider: Cloud.Provider
    let changed: () -> Void
    @State private var draft = ""
    @State private var saved = false
    @State private var checking = false
    @State private var message: String?

    var body: some View {
        Section(provider.title) {
            if saved {
                HStack {
                    Label("Key saved in your Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(Color.glacier)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        Cloud.setKey(nil, for: provider)
                        saved = false
                        message = nil
                        changed()
                    }
                }
            } else {
                HStack {
                    SecureField("API key", text: $draft)
                        .textContentType(.password)
                        .onSubmit(save)
                    if checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Save", action: save).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Link("Get a \(provider.title) key", destination: provider.keyPage).font(.callout)
            }
            Text("Speech: \(provider.speechModel) · Tidy: \(provider.chatModel)")
                .font(.callout).foregroundStyle(.secondary)
            if let message {
                Text(message).font(.callout).foregroundStyle(Color.ink)
            }
        }
        .onAppear { saved = Cloud.key(for: provider) != nil }
    }

    /// Checks the key with a free model listing before keeping it.
    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !checking else { return }
        checking = true
        message = nil
        Task {
            defer { checking = false }
            do {
                try await Cloud.verify(key, with: provider)
            } catch Cloud.Failure.offline {
                message = "Couldn't reach \(provider.title) to check the key. Saved anyway."
            } catch {
                message = error.localizedDescription
                return
            }
            guard Cloud.setKey(key, for: provider) else { message = "Couldn't save the key to your Keychain."; return }
            draft = ""
            saved = true
            changed()
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
