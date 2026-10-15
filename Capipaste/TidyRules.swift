import Foundation

/// What a rewrite has to pass before it replaces what you said; anything else keeps the raw note.
enum TidyRules {
    /// The cleaned rewrite, or nil when it can't be trusted.
    static func accept(_ rewrite: String, for note: String) -> String? {
        let result = clean(rewrite)
        guard !result.isEmpty,
              result.count <= note.count * 2 + 60, // much longer than the note: it invented things
              result.count >= note.count / 4,      // much shorter: it dropped the point
              numbers(in: note).isSubset(of: numbers(in: result)), // every number survives
              ownWords(result, in: note) >= 0.8 // mostly the speaker's words, not a paraphrase
        else { return nil }
        return result
    }

    /// Light tidy: drops ums and ahs and a phrase said twice in a row. Never rewords anything.
    static func light(_ text: String) -> String {
        var text = text.replacingOccurrences(of: #"(?i),?\s*\b(u+m+|u+h+m*|e+r+m+|e+r+|a+h+|a+w+|h+m+|m{2,})\b,?"#,
                                             with: " ", options: .regularExpression)
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let key = { (w: String) in w.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        // ponytail: also collapses intended doubles ("very very", "had had"); add an allowlist if that bites
        var i = 0
        while i < words.count {
            var dropped = false
            for n in stride(from: min(4, (words.count - i) / 2), through: 1, by: -1)
            where (0..<n).allSatisfy({ key(words[i + $0]) == key(words[i + n + $0]) }) && !key(words[i]).isEmpty {
                words.removeSubrange(i..<i + n) // keep the second copy, it carries the trailing punctuation
                dropped = true
                break
            }
            if !dropped { i += 1 }
        }
        text = words.joined(separator: " ")
            .replacingOccurrences(of: #"\s+([,.?!])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"^[,.\s]+"#, with: "", options: .regularExpression)
        return text.replacing(try! Regex(#"(^|[.?!]\s+)[a-z]"#)) { $0.output[0].substring!.uppercased() } // a dropped "Ah," leaves "and" opening a sentence
    }

    /// Share of the rewrite's words that the speaker actually said.
    // ponytail: bag-of-words, so a reorder passes; 0.8 leaves room for "it's"→"it is" and fixed punctuation
    static func ownWords(_ rewrite: String, in note: String) -> Double {
        let words = { (t: String) in t.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init) }
        let said = Set(words(note)), used = words(rewrite)
        return used.isEmpty ? 0 : Double(used.filter(said.contains).count) / Double(used.count)
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
