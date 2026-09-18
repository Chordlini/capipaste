import AVFoundation
import AppKit

/// Short screen recordings for bugs a still can't show (hover states, animations).
enum Clip {
    static let maxSeconds = 30

    struct Recording {
        let movie: URL
        /// Frames spread through the clip, for agents that can't watch video.
        let frames: [NSImage]
        let seconds: Int
    }

    /// Native macOS video picker: drag a region, press Record, stop from the menu bar.
    /// `-autoclip x,y,w,h` records 3 s of a fixed rect instead (testing).
    static func record() async -> Recording? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capipaste-\(UUID().uuidString).mov")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-autoclip"), i + 1 < args.count {
            process.arguments = ["-x", "-v", "-V3", "-R", args[i + 1], url.path]
        } else {
            process.arguments = ["-i", "-Jvideo", "-k", "-V\(maxSeconds)", url.path]
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in done.resume() }
            do { try process.run() } catch { done.resume() }
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        var frames: [NSImage] = []
        for t in [0.0, 0.33, 0.66, 0.97] {
            if let (cg, _) = try? await generator.image(at: CMTime(seconds: duration * t, preferredTimescale: 600)) {
                // Video frames are in pixels; show them at screen points like screenshots.
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                frames.append(NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)))
            }
        }
        trace("clip: \(String(format: "%.1f", duration)) s, \(frames.count) frames")
        guard !frames.isEmpty else { return nil }
        return Recording(movie: url, frames: frames, seconds: Int(duration.rounded()))
    }
}
