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
            if isNewer(latest.version, than: currentVersion) {
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
        do {
            status = .downloading(0)
            let (file, _) = try await URLSession.shared.download(from: zip)
            status = .downloading(0.6)
            let unpacked = FileManager.default.temporaryDirectory
                .appendingPathComponent("capipaste-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-xk", file.path, unpacked.path]
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0,
                  let app = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                      .first(where: { $0.pathExtension == "app" }) else {
                status = .failed("The download didn't contain an app.")
                return
            }
            guard try sameSigner(as: app) else {
                status = .failed("That build is signed by someone else — install it by hand.")
                return
            }
            let destination = Bundle.main.bundleURL
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: app)
            status = .readyToRelaunch
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// The download must be intact and signed, under Apple's root, by the team that signed this copy.
    /// (A certificate's name alone proves nothing: anyone can make one that says anything.)
    private func sameSigner(as candidate: URL) throws -> Bool {
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
        let rule = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let left = i < a.count ? a[i] : 0, right = i < b.count ? b[i] : 0
            if left != right { return left > right }
        }
        return false
    }
}
