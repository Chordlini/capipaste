// Run: swiftc Capipaste/Recordings.swift checks/recordings/main.swift -o /tmp/recordings-check && /tmp/recordings-check
// A take is saved as a playable .m4a beside its note, and pruning follows the Keep setting.
import AVFoundation

enum AppModel { static let capturesFolder = FileManager.default.temporaryDirectory.appendingPathComponent("recordings-check-\(UUID().uuidString)") }
func trace(_ message: String) { print(message) }
func wait(for url: URL) { for _ in 0..<50 where !FileManager.default.fileExists(atPath: url.path) { Thread.sleep(forTimeInterval: 0.1) }; Thread.sleep(forTimeInterval: 0.3) }

let folder = AppModel.capturesFolder
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder); UserDefaults.standard.removeObject(forKey: "keepRecordings") }
let tone: [Float] = (0..<32_000).map { i -> Float in Float(sin(Double(i) * 2 * Double.pi * 440 / 16_000) * 0.3) } // 2 s

UserDefaults.standard.set(Recordings.Keep.week.rawValue, forKey: "keepRecordings")
let note = folder.appendingPathComponent("Capipaste test.txt")
Recordings.save(tone, besides: note)
let m4a = folder.appendingPathComponent("Capipaste test.m4a")
wait(for: m4a)
let file = try! AVAudioFile(forReading: m4a)
let seconds = Double(file.length) / file.fileFormat.sampleRate
assert(abs(seconds - 2) < 0.2, "want ~2 s, got \(seconds)")
print("saved ok: \(String(format: "%.2f", seconds)) s")

Recordings.prune()
assert(FileManager.default.fileExists(atPath: m4a.path), "a fresh recording survives a week's pruning")
UserDefaults.standard.set(Recordings.Keep.never.rawValue, forKey: "keepRecordings")
Recordings.prune()
assert(!FileManager.default.fileExists(atPath: m4a.path), "turning recordings off deletes them")
Recordings.save(tone, besides: note)
Thread.sleep(forTimeInterval: 1)
assert(!FileManager.default.fileExists(atPath: m4a.path), "off means nothing is written")
print("prune ok")
