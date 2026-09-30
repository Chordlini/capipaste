import AppKit

/// Checks GitHub releases. You choose whether it only tells you, or installs by itself.
@MainActor @Observable
final class Updater {
    struct Release {
        let version: String
        let page: URL
        let zip: URL?
        let notes: String
    }

    enum Status: Equatable {
        case idle, checking, upToDate, available(String), downloading(Double), readyToRelaunch, failed(String)
    }

    static let repository = "Chordlini/capipaste"

    var status: Status = .idle
    var lastChecked: Date?
    private(set) var release: Release?

    var checkOnLaunch: Bool = UserDefaults.standard.object(forKey: "checkOnLaunch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(checkOnLaunch, forKey: "checkOnLaunch") }
    }
    /// Off by default: nothing replaces the app behind your back unless you ask.
    var installAutomatically: Bool = UserDefaults.standard.bool(forKey: "installAutomatically") {
        didSet { UserDefaults.standard.set(installAutomatically, forKey: "installAutomatically") }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func check() async {
        status = .checking
        do {
            let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init) else {
                status = .upToDate  // no releases published yet
                lastChecked = .now
                return
            }
            let assets = json["assets"] as? [[String: Any]] ?? []
            let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
                .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init) }
            let latest = Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "v")),
                                 page: page, zip: zip, notes: json["body"] as? String ?? "")
            release = latest
            lastChecked = .now
            if Self.isNewer(latest.version, than: currentVersion) {
                status = .available(latest.version)
                if installAutomatically, latest.zip != nil { await install() }
            } else {
                status = .upToDate
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Downloads the release zip, checks it is signed the same as this copy, swaps it in, relaunches.
    func install() async {
        guard let release, let zip = release.zip else { return }
        // Never replace this copy with an older (or the same) build.
        guard Self.isNewer(release.version, than: currentVersion) else { status = .upToDate; return }
        let unpacked = FileManager.default.temporaryDirectory
            .appendingPathComponent("capipaste-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: unpacked) }
        do {
            status = .downloading(0)
            let (file, _) = try await URLSession.shared.download(from: zip)
            defer { try? FileManager.default.removeItem(at: file) }
            status = .downloading(0.6)
            // Unzipping and checking every signature takes seconds: off the main thread.
            let outcome: String? = try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-xk", file.path, unpacked.path]
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0,
                      let app = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                          .first(where: { $0.pathExtension == "app" }) else {
                    return "The download didn't contain an app."
                }
                guard Self.sameSigner(as: app) else { return "That build is signed by someone else — install it by hand." }
                _ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: app)
                return nil
            }.value
            if let outcome { status = .failed(outcome); return }
            status = .readyToRelaunch
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// The download must be intact and signed, under Apple's root, by the team that signed this copy.
    /// (A certificate's name alone proves nothing: anyone can make one that says anything.)
    nonisolated private static func sameSigner(as candidate: URL) -> Bool {
        var mine: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &mine) == errSecSuccess, let mine,
              SecCodeCopySigningInformation(mine, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty, team.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        return Self.isValid(candidate, team: team)
    }

    nonisolated static func isValid(_ app: URL, team: String) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        // Same team AND this app: another app the team signed must not be able to replace Capipaste.
        let rule = "anchor apple generic and identifier \"com.chordlini.capipaste\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// `0.2.10` beats `0.2.9`; a suffix like `-beta` or `rc1` reads as its leading number.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let left = i < a.count ? a[i] : 0, right = i < b.count ? b[i] : 0
            if left != right { return left > right }
        }
        return false
    }
}
