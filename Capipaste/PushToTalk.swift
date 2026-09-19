import AppKit

/// Hold a modifier key to dictate. Watches ⌘ (or ⌥/⌃) press-and-hold globally, and ignores
/// the key the moment it's used as part of a shortcut.
@MainActor
final class PushToTalk {
    enum Trigger: String, CaseIterable, Identifiable {
        case rightCommand, leftCommand, rightOption, off

        var id: String { rawValue }

        var title: String {
            switch self {
            case .rightCommand: "Hold right ⌘"
            case .leftCommand: "Hold left ⌘"
            case .rightOption: "Hold right ⌥"
            case .off: "Off"
            }
        }

        /// Virtual key codes from Carbon's keyboard map.
        var keyCode: UInt16? {
            switch self {
            case .rightCommand: 54
            case .leftCommand: 55
            case .rightOption: 61
            case .off: nil
            }
        }

        var modifier: NSEvent.ModifierFlags {
            self == .rightOption ? .option : .command
        }
    }

    var trigger: Trigger {
        didSet {
            UserDefaults.standard.set(trigger.rawValue, forKey: "pushToTalk")
            restart()
        }
    }
    /// Recording starts the instant the key goes down — waiting would clip your first word.
    /// If another key or click arrives inside this window the take is thrown away, so ⌘C
    /// and friends never leave a stray bar behind.
    static let shortcutWindow: Duration = .milliseconds(400)

    private var monitors: [Any] = []
    /// Watches other keys and clicks, only while the trigger is held.
    private var interruptMonitor: Any?
    private var holdTask: Task<Void, Never>?
    private var holding = false
    private var armed = false
    private let onStart: () -> Void
    private let onAbort: () -> Void
    private let onStop: () -> Void

    init(onStart: @escaping () -> Void, onAbort: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.onStart = onStart
        self.onAbort = onAbort
        self.onStop = onStop
        trigger = Trigger(rawValue: UserDefaults.standard.string(forKey: "pushToTalk") ?? "") ?? .rightCommand
        restart()
    }

    func restart() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        cancelHold()
        let trusted = AXIsProcessTrusted()
        trace("pushToTalk: arm trigger=\(trigger.rawValue) accessibility=\(trusted)")
        guard trigger != .off, trusted else { return }

        let flags: NSEvent.EventTypeMask = [.flagsChanged]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: flags, handler: { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }) { monitors.append(global) }

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: flags) { [weak self] event in
            self?.handle(event)
            return event
        } as Any)
    }

    private func handle(_ event: NSEvent) {
        guard let code = trigger.keyCode else { return }
        let pressed = event.modifierFlags.contains(trigger.modifier)
        if event.keyCode == code, pressed {
            guard !holding else { return }
            holding = true
            armed = false
            // Any other key or click while holding means the modifier is part of a shortcut, not speech.
            // Installed per hold, so the rest of the day's typing never reaches this app.
            interruptMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] _ in
                Task { @MainActor in self?.cancelHold() }
            }
            onStart()
            holdTask = Task { [weak self] in
                try? await Task.sleep(for: Self.shortcutWindow)
                guard !Task.isCancelled, let self else { return }
                armed = true   // past the window: this is speech, not a shortcut
                holdTask = nil
            }
        } else if !pressed, holding {
            stopWatchingInterrupts()
            let wasArmed = armed
            holding = false
            armed = false
            holdTask?.cancel()
            holdTask = nil
            // a quick tap is just the modifier being tapped: throw the take away
            wasArmed ? onStop() : onAbort()
        }
    }

    /// Another key or a click: the modifier is part of a shortcut, so drop the take.
    private func cancelHold() {
        stopWatchingInterrupts()
        holdTask?.cancel()
        holdTask = nil
        guard holding else { return }
        holding = false
        armed = false
        trace("pushToTalk: shortcut detected, take dropped")
        onAbort()
    }

    private func stopWatchingInterrupts() {
        interruptMonitor.map(NSEvent.removeMonitor)
        interruptMonitor = nil
    }

    deinit {
        let taken = monitors
        Task { @MainActor in taken.forEach(NSEvent.removeMonitor) }
    }
}
