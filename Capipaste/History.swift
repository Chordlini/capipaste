import AppKit

/// Past captures: each one's note is saved as a .txt next to its PNG in the captures folder.
enum History {
    struct Entry: Identifiable {
        let note: URL
        let date: Date
        let text: String
        var id: URL { note }

        /// First line of what was said, or a stand-in when there was no note.
        var title: String {
            let first = text.components(separatedBy: "\n").first ?? ""
            return first.hasPrefix("[screenshot") || first.hasPrefix("Text in the screenshot") || first.isEmpty ? "Screenshot" : first
        }

        /// The PNGs named in the note's `[screenshot…: path]` lines, if they still exist.
        var images: [URL] {
            text.components(separatedBy: "\n").compactMap { line in
                guard line.hasPrefix("[screenshot"), let colon = line.firstIndex(of: ":") else { return nil }
                let path = line[line.index(after: colon)...].dropLast().trimmingCharacters(in: .whitespaces)
                return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
            }
        }
    }

    static func save(_ text: String, besides png: URL) {
        let name = png.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " (1)", with: "")
        try? text.write(to: png.deletingLastPathComponent().appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    }

    static func recent(_ limit: Int = 10) -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: AppModel.capturesFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "txt" }
            .compactMap { url -> Entry? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return Entry(note: url, date: date, text: text)
            }
            .sorted { $0.date > $1.date }
            .prefix(limit).map { $0 }
    }

    /// Puts a past capture back on the clipboard, exactly as it was delivered.
    static func copy(_ entry: Entry, textOnly: Bool) {
        let images = entry.images
        let pngs = images.compactMap { try? Data(contentsOf: $0) }
        Output.copy(pngs: pngs, urls: images, text: entry.text, textOnly: textOnly || pngs.isEmpty)
    }
}
