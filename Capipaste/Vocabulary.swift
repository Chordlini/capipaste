import Foundation

/// Your words, one per line in Settings: `useEffect` teaches the spelling (and biases Nemotron),
/// `super base = Supabase` replaces a mishearing outright.
enum Vocabulary {
    static var lines: [String] {
        (UserDefaults.standard.string(forKey: "vocabulary") ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static var words: [String] {
        lines.map { $0.components(separatedBy: "=").last!.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static var replacements: [(from: String, to: String)] {
        lines.compactMap { line in
            let sides = line.components(separatedBy: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            guard sides.count == 2, !sides[0].isEmpty, !sides[1].isEmpty else { return nil }
            return (sides[0], sides[1])
        }
    }

    /// camelCase / PascalCase names on screen (`PricingCards`, `useEffect`): what you're likely to say.
    static func identifiers(in text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { parts(of: $0).count >= 2 && $0.count <= 40 && seen.insert($0).inserted }
            .prefix(50).map { $0 }
    }

    /// Fixes spelling in a transcript: replacements first, then each word matched loosely
    /// (any case, spaces or hyphens between its parts).
    static func apply(_ text: String, words: [String], replacements: [(from: String, to: String)]) -> String {
        var text = text
        for (from, to) in replacements {
            text = replace(in: text, pattern: "\\b" + NSRegularExpression.escapedPattern(for: from) + "\\b", with: to)
        }
        for word in words.sorted(by: { $0.count > $1.count }) {
            let loose = parts(of: word).map(NSRegularExpression.escapedPattern(for:)).joined(separator: "[\\s-]?")
            text = replace(in: text, pattern: "\\b" + loose + "\\b", with: word)
        }
        return text
    }

    /// `useEffect` → use, Effect · `iOS` → i, OS · `PricingCards2` → Pricing, Cards2
    static func parts(of word: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var previous: Character?
        for c in word {
            if let p = previous, p.isLowercase, c.isUppercase { parts.append(current); current = "" }
            current.append(c)
            previous = c
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func replace(in text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }
}
