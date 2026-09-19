// Run: swiftc Capipaste/Updater.swift checks/updater/main.swift -o /tmp/updater-check && /tmp/updater-check
// Needs a signed build in /Applications. The updater must accept that build and refuse a tampered or re-signed copy.
import Foundation

func sh(_ command: String) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", command]; try! p.run(); p.waitUntilExit() }
let team = "TN6J66CQA6"
let real = URL(fileURLWithPath: "/Applications/Capipaste.app")
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("updater-check-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: tmp) }
let tampered = tmp.appendingPathComponent("tampered/Capipaste.app"), resigned = tmp.appendingPathComponent("resigned/Capipaste.app")
sh("mkdir -p '\(tmp.path)/tampered' '\(tmp.path)/resigned' && cp -R '\(real.path)' '\(tampered.path)' && cp -R '\(real.path)' '\(resigned.path)'")
sh("printf x >> '\(tampered.path)/Contents/MacOS/Capipaste'")           // same signature, changed binary
sh("codesign -f -s - --deep '\(resigned.path)' 2>/dev/null")             // someone else's (ad-hoc) signature

assert(Updater.isValid(real, team: team), "the real build must pass")
assert(!Updater.isValid(real, team: "AAAAAAAAAA"), "another team must fail")
assert(!Updater.isValid(tampered, team: team), "a changed binary must fail")
assert(!Updater.isValid(resigned, team: team), "a re-signed copy must fail")
print("updater signature checks ok")
