import AppKit

/// Where a capture came from: the app, its window title and, for browsers, the page URL.
struct CaptureContext {
    var app: String
    var window: String?
    var url: String?

    static var enabled: Bool { UserDefaults.standard.object(forKey: "context") as? Bool ?? true }

    /// `Context: Safari — "Pricing – Acme" — http://localhost:3000/pricing`
    var line: String {
        (["Context: \(app)"] + [window.map { "\"\($0)\"" }, url].compactMap { $0 }).joined(separator: " — ")
    }

    /// Read before the region picker takes focus. The URL needs Automation permission for the browser.
    static func read(from app: NSRunningApplication?) async -> CaptureContext? {
        guard enabled, let app, let name = app.localizedName else { return nil }
        var context = CaptureContext(app: name)
        context.window = focusedWindowTitle(of: app)
        if let script = urlScript(for: app.bundleIdentifier) { context.url = await run(script) }
        return context
    }

    /// Needs Accessibility (already asked for hold-to-talk); nil without it.
    private static func focusedWindowTitle(of app: NSRunningApplication) -> String? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return nil }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        let text = (title as? String)?.trimmingCharacters(in: .whitespaces)
        return text?.isEmpty == false ? text : nil
    }

    private static func urlScript(for bundleID: String?) -> String? {
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return "tell application id \"\(bundleID!)\" to return URL of front document"
        case "com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "org.chromium.Chromium":
            return "tell application id \"\(bundleID!)\" to return URL of active tab of front window"
        default:
            return nil
        }
    }

    /// osascript off the main thread, so a first-time permission prompt can't freeze the app.
    private static func run(_ script: String) async -> String? {
        await withCheckedContinuation { done in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            process.terminationHandler = { _ in
                let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                done.resume(returning: text?.isEmpty == false ? text : nil)
            }
            do { try process.run() } catch { done.resume(returning: nil) }
        }
    }
}
