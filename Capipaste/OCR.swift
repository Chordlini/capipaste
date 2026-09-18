import AppKit
import Vision

/// Reads the text in a capture so terminals (which only get text) still see what was on screen.
enum OCR {
    enum Mode: String, CaseIterable, Identifiable {
        case terminals, always, never
        var id: String { rawValue }
        var title: String {
            switch self {
            case .terminals: "Terminals only"
            case .always: "Always"
            case .never: "Never"
            }
        }
        static var current: Mode {
            Mode(rawValue: UserDefaults.standard.string(forKey: "ocrMode") ?? "") ?? .terminals
        }
    }

    /// Lines of text in reading order, or "" if there's none.
    static func text(in image: NSImage) async -> String {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
        let started = Date()
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false // code and paths must not be "corrected" into English
        let lines = (try? await request.perform(on: cg))?.compactMap { $0.topCandidates(1).first?.string } ?? []
        trace("ocr: \(lines.count) lines in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        // ponytail: 4000-char cap keeps a full-screen grab from flooding the prompt
        return String(lines.joined(separator: "\n").prefix(4000))
    }
}
