// Run: scripts/check.sh (compiles TidyRules, Recorder, Output, History, Recordings, Clip, Updater with this file)
// Pure logic behind the card, the mic, tidy and updates: no app, no mic, no network.
import AppKit

enum AppModel { static let capturesFolder = FileManager.default.temporaryDirectory.appendingPathComponent("logic-check-\(UUID().uuidString)") }
func trace(_ message: String) {}
let hookArguments: [String] = []
func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
    precondition(ok, what, file: file, line: line) // precondition, not assert: still checks in -O builds
}

// MARK: Tidy accepts a rewrite only when it's safe to replace what you said
let note = "so um the save button uh it's grey on port 3000 when it should be blue"
check(TidyRules.accept("The save button is grey on port 3000; make it blue.", for: note) == "The save button is grey on port 3000; make it blue.", "good rewrite")
check(TidyRules.accept("The save button is grey; make it blue.", for: note) == nil, "a dropped number is refused")
check(TidyRules.accept("Blue.", for: note) == nil, "far shorter: dropped the point")
check(TidyRules.accept(String(repeating: "Invented detail. ", count: 20) + "3000", for: note) == nil, "far longer: invented things")
check(TidyRules.accept("  ", for: note) == nil, "empty")
check(TidyRules.accept("<think>port 3000 hmm</think>\n\"The save button on port 3000 is grey; make it blue.\"", for: note)
      == "The save button on port 3000 is grey; make it blue.", "reasoning and quotes stripped")
check(TidyRules.numbers(in: "v2.10 at 3:45") == ["2", "10", "3", "45"], "numbers")
print("tidy rules ok")

// MARK: Meter and stuck-mic detection
check(Recorder.level(rms: 0) == 0 && Recorder.level(rms: 1) == 1, "level ends")
check(abs(Recorder.level(rms: pow(10, -30 / 20)) - 0.5) < 0.001, "-30 dB sits mid-meter")
check(Recorder.level(rms: .nan) == 0 && Recorder.level(rms: 5) == 1, "level clamps garbage")
let stuck = SilenceWatch()
check((0..<15).allSatisfy { _ in !stuck.stuck(0) } && stuck.stuck(0), "16 zero buffers from the start = stuck")
check(!stuck.stuck(0), "reported once")
let fine = SilenceWatch()
check(!fine.stuck(0.01) && (0..<50).allSatisfy { _ in !fine.stuck(0) }, "a real signal first: later silence is just a pause")
print("recorder ok")

// MARK: Updates
check(Updater.isNewer("0.2.10", than: "0.2.9"), "numeric, not text")
check(!Updater.isNewer("1.0", than: "1.0.0") && !Updater.isNewer("0.2.1", than: "0.2.1"), "equal")
check(Updater.isNewer("v0.3.0", than: "0.2.1"), "tag prefix")
check(Updater.isNewer("0.3.1-beta", than: "0.3.0") && !Updater.isNewer("0.2.0", than: "0.3.0"), "suffix and older")
print("updater versions ok")

// MARK: Eraser and shapes
let line = Stroke(points: (0...20).map { CGPoint(x: Double($0) * 5, y: 0) })
let cut = Stroke.erase([line], at: CGPoint(x: 50, y: 0), radius: 6)
check(cut.count == 2 && cut.allSatisfy { $0.kind == .pen }, "a line erased in the middle splits in two")
check(cut.flatMap(\.points).allSatisfy { abs($0.x - 50) > 6 }, "only points under the eraser go")
check(Stroke.erase([line], at: CGPoint(x: 50, y: 40), radius: 6).count == 1, "far away: untouched")
let box = Stroke(kind: .box, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40)])
check(box.touches(CGPoint(x: 35, y: 11), radius: 3) && !box.touches(CGPoint(x: 35, y: 25), radius: 3), "box: edge yes, inside no")
let blur = Stroke(kind: .blur, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40)])
check(blur.touches(CGPoint(x: 35, y: 25), radius: 3), "blur: anywhere inside")
let arrow = Stroke(kind: .arrow, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
check(arrow.touches(CGPoint(x: 50, y: 2), radius: 3) && !arrow.touches(CGPoint(x: 50, y: 9), radius: 3), "arrow shaft")
check(Stroke.erase([box, arrow], at: CGPoint(x: 35, y: 10), radius: 3).map(\.kind) == [.arrow], "a touched shape goes whole")
check(!Stroke(kind: .arrow, points: [.zero, .zero]).path().isEmpty, "zero-length arrow still draws")
check(!Stroke(points: [CGPoint(x: 3, y: 3)]).path().isEmpty, "a single-point dot draws")
print("strokes ok")

// MARK: Rendering: blur covers what's under it and nothing else
func pixel(_ png: Data, _ x: Int, _ y: Int) -> NSColor { NSBitmapImageRep(data: png)!.colorAt(x: x, y: y)! }
let size = 200
let stripes = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
    for x in stride(from: 0, to: size, by: 2) {
        (x % 4 == 0 ? NSColor.black : NSColor.white).setFill()
        NSRect(x: x, y: 0, width: 2, height: size).fill()
    }
    return true
}
let plain = Output.render(stripes, strokes: [], lineWidth: 4)!
let blurred = Output.render(stripes, strokes: [Stroke(kind: .blur, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)])], lineWidth: 4)!
let rep = NSBitmapImageRep(data: blurred)!
check(rep.pixelsWide == NSBitmapImageRep(data: plain)!.pixelsWide, "same size out")
let scale = rep.pixelsWide / size
func distinct(_ png: Data, x: Range<Int>, y: Int) -> Int { Set(x.map { pixel(png, $0 * scale, y * scale).redComponent }).count }
check(distinct(plain, x: 10..<30, y: 50) > 1, "stripes to start with")
check(distinct(blurred, x: 10..<22, y: 50) == 1, "under the blur box: one flat block, no stripes")
check(distinct(blurred, x: 150..<170, y: 150) > 1, "outside the box: untouched")
print("render ok")

// MARK: Files: names never collide, the note reads back
let folder = AppModel.capturesFolder
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let now = Date()
let first = Output.stamp(in: folder, now: now)
FileManager.default.createFile(atPath: folder.appendingPathComponent("Capipaste \(first).png").path, contents: Data())
let second = Output.stamp(in: folder, now: now)
check(second == first + " 2", "same second: \(second)")
FileManager.default.createFile(atPath: folder.appendingPathComponent("Capipaste \(second) (1).png").path, contents: Data())
check(Output.stamp(in: folder, now: now) == first + " 3", "multi-shot names count as taken")

let shot = folder.appendingPathComponent("Capipaste \(first).png")
let saved = History.save("Make it blue.\n\n[screenshot: \(shot.path)]\n[screenshot 2: /nope/missing.png]", besides: shot)
let entry = History.recent(1).first!
check(entry.note.resolvingSymlinksInPath() == saved.resolvingSymlinksInPath() && entry.title == "Make it blue.", "title is the first line: \(entry.note) \(saved) \(entry.title)")
check(entry.images == [shot], "only screenshots that still exist")
History.save("[screenshot: \(shot.path)]", besides: folder.appendingPathComponent("Capipaste x (1).png"))
check(History.recent(1).first?.title == "Screenshot" && History.recent(1).first?.note.lastPathComponent == "Capipaste x.txt", "no note: stand-in title, (1) dropped")
print("files ok")

// MARK: Mic choice
let builtIn = AudioInput(id: 1, uid: "built-in", name: "MacBook Pro Microphone", isDefault: false, isBuiltIn: true)
let airpods = AudioInput(id: 2, uid: "airpods", name: "AirPods", isDefault: true, isBluetooth: true)
let usb = AudioInput(id: 3, uid: "usb", name: "USB mic", isDefault: false)
check(AudioInput.choose(from: [builtIn, airpods, usb], picked: nil, avoidBluetooth: true)?.uid == "built-in", "headset default gives way")
check(AudioInput.choose(from: [builtIn, airpods, usb], picked: nil, avoidBluetooth: false)?.uid == "airpods", "unless you turn that off")
check(AudioInput.choose(from: [builtIn, airpods, usb], picked: "airpods", avoidBluetooth: true)?.uid == "airpods", "your pick always wins")
check(AudioInput.choose(from: [builtIn, airpods, usb], picked: "gone", avoidBluetooth: true)?.uid == "built-in", "unplugged pick falls back")
check(AudioInput.choose(from: [airpods], picked: nil, avoidBluetooth: true)?.uid == "airpods", "no built-in mic: the headset it is")
check(AudioInput.choose(from: [], picked: nil, avoidBluetooth: true) == nil, "no mics")
print("mic choice ok")

// MARK: Dictation paste puts your clipboard back (on a private pasteboard, never yours)
MainActor.assumeIsolated {
    let board = NSPasteboard(name: NSPasteboard.Name("capipaste-check-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    PasteSession.board = board
    PasteSession.giveUp = 0.6
    func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    func copy(_ text: String) { board.clearContents(); board.setString(text, forType: .string) }

    copy("what you had copied")
    PasteSession.start("the dictated note")
    PasteSession.current?.pasted()
    check(board.string(forType: .string) == "the dictated note", "the paste reads the note")
    check(board.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true, "clipboard managers told to skip it")
    spin(0.5)
    check(board.string(forType: .string) == "what you had copied", "then your clipboard is back")

    copy("what you had copied")
    PasteSession.start("second note")
    PasteSession.current?.pasted()
    _ = board.string(forType: .string)
    copy("something you copied right after") // before the restore fires
    spin(0.5)
    check(board.string(forType: .string) == "something you copied right after", "a newer copy is never overwritten")

    copy("what you had copied")
    PasteSession.start("nobody pasted this")
    spin(0.9) // never read (no Accessibility, or no text field)
    check(board.string(forType: .string) == "nobody pasted this", "unread: the note stays on the clipboard")

    board.clearContents()
    PasteSession.start("into an empty clipboard")
    PasteSession.current?.pasted()
    _ = board.string(forType: .string)
    spin(0.5)
    check(board.string(forType: .string) == nil, "an empty clipboard comes back empty")
}
print("paste restore ok")
print("logic checks passed")
