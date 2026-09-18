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
    /// How long the key must be held before dictation starts (so ⌘C never triggers it).
    static let holdDelay: Duration = .milliseconds(350)

    private var monitors: [Any] = []
    private var holdTask: Task<Void, Never>?
    private var holding = false
    private let onStart: () -> Void
    private let onStop: () -> Void

    init(onStart: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.onStart = onStart
        self.onStop = onStop
        trigger = Trigger(rawValue: UserDefaults.standard.string(forKey: "pushToTalk") ?? "") ?? .rightCommand
        restart()
    }

    func restart() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        cancelHold()
        guard trigger != .off, AXIsProcessTrusted() else { return }

        let flags: NSEvent.EventTypeMask = [.flagsChanged]
        // Any other key or click while holding means the modifier is part of a shortcut, not speech.
        let interrupts: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: flags, handler: { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }) { monitors.append(global) }

        if let globalInterrupt = NSEvent.addGlobalMonitorForEvents(matching: interrupts, handler: { [weak self] _ in
            Task { @MainActor in self?.cancelHold() }
        }) { monitors.append(globalInterrupt) }

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: flags) { [weak self] event in
            self?.handle(event)
            return event
        } as Any)
    }

    private func handle(_ event: NSEvent) {
        guard let code = trigger.keyCode else { return }
        let pressed = event.modifierFlags.contains(trigger.modifier)
        if event.keyCode == code, pressed {
            guard !holding, holdTask == nil else { return }
            holdTask = Task { [weak self] in
                try? await Task.sleep(for: Self.holdDelay)
                guard !Task.isCancelled, let self else { return }
                holding = true
                holdTask = nil
                onStart()
            }
        } else if !pressed {
            cancelHold()
            if holding {
                holding = false
                onStop()
            }
        }
    }

    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
    }

    deinit {
        let taken = monitors
        Task { @MainActor in taken.forEach(NSEvent.removeMonitor) }
    }
}
