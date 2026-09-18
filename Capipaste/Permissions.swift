import AVFoundation
import CoreGraphics
import SwiftUI

/// The two permissions macOS requires before Capipaste can work, and how to grant them.
@MainActor @Observable
final class Permissions {
    enum State { case granted, notAsked, denied }

    struct Step: Identifiable {
        let id: Int
        let title: String
        let why: String
        let state: State
        let settings: String  // System Settings pane anchor
    }

    private(set) var screen: State = .notAsked
    private(set) var mic: State = .notAsked
    /// Screen Recording only takes effect after a relaunch, so remember we asked.
    private(set) var screenNeedsRestart = false

    /// `-setupdemo` pretends nothing is granted yet, to check the setup steps.
    let demo = CommandLine.arguments.contains("-setupdemo")
    var ready: Bool { !demo && screen == .granted && mic == .granted }

    var steps: [Step] {
        [
            Step(id: 1, title: "Screen Recording", why: "so ⌘⇧S can capture what's on screen",
                 state: screen, settings: "Privacy_ScreenCapture"),
            Step(id: 2, title: "Microphone", why: "so you can say what should change",
                 state: mic, settings: "Privacy_Microphone"),
        ]
    }

    var remaining: Int { steps.filter { $0.state != .granted }.count }

    func refresh() {
        if demo { screen = .notAsked; mic = .denied; return }
        let hadScreen = screen == .granted
        screen = CGPreflightScreenCaptureAccess() ? .granted : .notAsked
        if screen == .granted, !hadScreen { screenNeedsRestart = false }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = .granted
        case .notDetermined: mic = .notAsked
        default: mic = .denied
        }
    }

    /// Asks macOS directly when it still can; otherwise sends the user to Settings.
    func request(_ step: Step) {
        switch step.id {
        case 1:
            if screen != .granted {
                // macOS shows its prompt once; afterwards it only listens to Settings.
                screenNeedsRestart = true
                CGRequestScreenCaptureAccess()
                openSettings(step)
            }
        default:
            if mic == .notAsked {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    Task { @MainActor in self.refresh() }
                }
            } else if mic == .denied {
                openSettings(step)
            }
        }
        refresh()
    }

    func openSettings(_ step: Step) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(step.settings)")!
        NSWorkspace.shared.open(url)
    }

    /// Screen Recording only applies to a fresh launch.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
