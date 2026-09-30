import Foundation

/// What a rewrite has to pass before it replaces what you said; anything else keeps the raw note.
enum TidyRules {
    /// The cleaned rewrite, or nil when it can't be trusted.
    static func accept(_ rewrite: String, for note: String) -> String? {
        let result = clean(rewrite)
        guard !result.isEmpty,
              result.count <= note.count * 2 + 60, // much longer than the note: it invented things
              result.count >= note.count / 4,      // much shorter: it dropped the point
              numbers(in: note).isSubset(of: numbers(in: result)) // every number survives
        else { return nil }
        return result
    }

    static func numbers(in text: String) -> Set<String> {
        Set(text.split(whereSeparator: { !$0.isNumber }).map(String.init))
    }

    /// Drops a reasoning preamble and wrapping quotes.
    static func clean(_ text: String) -> String {
        var text = text
        for tag in ["</think>", "</reasoning>"] {
            if let end = text.range(of: tag, options: .backwards) { text = String(text[end.upperBound...]) }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
    }
}
