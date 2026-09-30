import AVFoundation

/// The voice behind each note, saved as an .m4a next to its .txt for as long as Settings says.
enum Recordings {
    enum Keep: Int, CaseIterable, Identifiable {
        case never = 0, day = 1, week = 7, month = 30, forever = -1
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .never: "Don't keep recordings"
            case .day: "1 day"
            case .week: "1 week"
            case .month: "30 days"
            case .forever: "Forever"
            }
        }
    }

    static var keep: Keep {
        Keep(rawValue: UserDefaults.standard.object(forKey: "keepRecordings") as? Int ?? Keep.week.rawValue) ?? .week
    }

    /// `note` is the saved .txt; the audio lands beside it with the same name.
    static func save(_ samples: [Float], besides note: URL) {
        guard keep != .never, !samples.isEmpty else { return }
        let url = note.deletingPathExtension().appendingPathExtension("m4a")
        Task.detached(priority: .utility) {
            do {
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                                               AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
                let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
                samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                try file.write(from: buffer)
                trace("recordings: saved \(url.lastPathComponent), \(samples.count / 16_000) s")
            } catch {
                trace("recordings: save failed \(error)")
                try? FileManager.default.removeItem(at: url) // no half-written .m4a left behind
            }
            prune()
        }
    }

    /// Deletes recordings older than the setting allows (all of them when it's off).
    static func prune() {
        let keep = keep
        guard keep != .forever else { return }
        let cutoff = Date().addingTimeInterval(-Double(keep.rawValue) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: AppModel.capturesFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        // Only our own takes: an .m4a you dropped into the folder yourself is left alone.
        for file in files where file.pathExtension == "m4a" && file.lastPathComponent.hasPrefix("Capipaste ") {
            let made = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if made < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }
}
