import Foundation
import Security

/// Bring-your-own-key speech and tidy through OpenAI or Groq (both speak the OpenAI API).
/// Nothing is sent anywhere unless you pick a provider and paste a key; keys live in the Keychain.
enum Cloud {
    enum Provider: String, CaseIterable, Identifiable, Sendable {
        case openai, groq

        var id: String { rawValue }

        var title: String {
            switch self {
            case .openai: "OpenAI"
            case .groq: "Groq"
            }
        }

        var base: URL {
            switch self {
            case .openai: URL(string: "https://api.openai.com/v1/")!
            case .groq: URL(string: "https://api.groq.com/openai/v1/")!
            }
        }

        var speechModel: String {
            switch self {
            case .openai: "gpt-transcribe"
            case .groq: "whisper-large-v3-turbo"
            }
        }

        var chatModel: String {
            switch self {
            case .openai: "gpt-6-luna"
            case .groq: "openai/gpt-oss-20b"
            }
        }

        /// Both tidy models reason by default; a rewrite doesn't need it and it costs a second or more.
        var chatExtras: [String: Any] {
            switch self {
            case .openai: ["reasoning_effort": "none"]
            case .groq: ["reasoning_effort": "low", "include_reasoning": false]
            }
        }

        var keyPage: URL {
            switch self {
            case .openai: URL(string: "https://platform.openai.com/api-keys")!
            case .groq: URL(string: "https://console.groq.com/keys")!
            }
        }

        /// What the provider will take in one upload.
        var maxUploadBytes: Int { 25 * 1_000_000 }
    }

    enum Failure: Error, Equatable, LocalizedError {
        case noKey, badKey, tooLarge, rateLimited, offline, server(Int, String), unreadable

        var errorDescription: String? {
            switch self {
            case .noKey: "No API key yet."
            case .badKey: "The API key was refused."
            case .tooLarge: "The recording is too long to upload."
            case .rateLimited: "Rate limited, try again in a moment."
            case .offline: "Couldn't reach the server."
            case let .server(code, message): "Server error \(code)\(message.isEmpty ? "" : ": \(message)")"
            case .unreadable: "The server's answer made no sense."
            }
        }
    }

    // MARK: Keys

    /// Swapped by the checks so they never touch your real keys.
    nonisolated(unsafe) static var keychainService = "com.chordlini.capipaste.api-key"

    static func key(for provider: Provider) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: provider.rawValue,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    /// Saves (or with nil/empty, removes) the key for `provider`.
    @discardableResult
    static func setKey(_ key: String?, for provider: Provider) -> Bool {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: provider.rawValue]
        SecItemDelete(match as CFDictionary)
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { return true }
        var add = match
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    // MARK: Requests

    /// Swapped by the checks for a stubbed session.
    nonisolated(unsafe) static var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral // no cookies, no cache of what you said
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// 16 kHz mono speech → text. `words` are spellings to expect (your vocabulary, names on screen).
    static func transcribe(_ samples: [Float], with provider: Provider, words: [String] = []) async throws -> String {
        guard let key = key(for: provider) else { throw Failure.noKey }
        let audio = wav(samples)
        guard audio.count < provider.maxUploadBytes else { throw Failure.tooLarge }
        let fields = speechFields(provider, words: words)
        let boundary = "capipaste-\(UUID().uuidString)"
        var request = URLRequest(url: provider.base.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // Upload time grows with the take: 30 s plus a second per 10 s of audio.
        request.timeoutInterval = 30 + Double(samples.count) / 160_000
        let body = multipart(boundary: boundary, fields: fields, file: audio, filename: "note.wav", mime: "audio/wav")
        let data = try await send(request, body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String
        else { throw Failure.unreadable }
        return cleaned(text)
    }

    /// Whisper labels silence and noise instead of leaving it empty: `[BLANK_AUDIO]`, `(music)`, `*coughs*`.
    static func cleaned(_ text: String) -> String {
        // Known noise labels only: brackets you actually dictate (`[1, 2]`, `foo(bar)`) stay.
        let noise = "(?:blank_audio|no speech|music|applause|laughter|silence|inaudible|noise|coughs?|sighs?)"
        let tags = #"\[\#(noise)[^\]]{0,20}\]|\(\#(noise)[^)]{0,20}\)|\*\#(noise)\*"#
        return text.replacingOccurrences(of: tags, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One system + user turn through chat completions; used by Tidy.
    static func chat(system: String, user: String, with provider: Provider) async throws -> String {
        guard let key = key(for: provider) else { throw Failure.noKey }
        var request = URLRequest(url: provider.base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        var payload: [String: Any] = [
            "model": provider.chatModel,
            "max_completion_tokens": 600,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        payload.merge(provider.chatExtras) { $1 }
        let data = try await send(request, body: try JSONSerialization.data(withJSONObject: payload))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String
        else { throw Failure.unreadable }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cheap key check for Settings: lists models, sends no audio.
    static func verify(_ key: String, with provider: Provider) async throws {
        var request = URLRequest(url: provider.base.appendingPathComponent("models"))
        request.setValue("Bearer \(key.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        _ = try await send(request, body: nil)
    }

    private static func send(_ request: URLRequest, body: Data?) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            if let body {
                (data, response) = try await session.upload(for: request, from: body)
            } else {
                (data, response) = try await session.data(for: request)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw Failure.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let failure = failure(status: status, body: data) { throw failure }
        return data
    }

    /// Maps an HTTP answer to what went wrong (nil when it went fine). Never echoes the key.
    static func failure(status: Int, body: Data) -> Failure? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return .badKey
        case 413: return .tooLarge
        case 429: return .rateLimited
        default:
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
            return .server(status, String(message.prefix(160)))
        }
    }

    // MARK: Encoding

    /// Form fields for a transcription. Whisper (Groq) only reads a 224-token prompt, so the words go in as
    /// a short spelling list; OpenAI's model also takes each one as a literal keyword.
    static func speechFields(_ provider: Provider, words: [String]) -> [(String, String)] {
        var fields = [("model", provider.speechModel), ("response_format", "json")]
        var seen = Set<String>()
        let words = words
            .map { $0.components(separatedBy: CharacterSet(charactersIn: "<>\r\n")).joined().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        // ponytail: ~600 characters stays under 224 tokens for plain words; count tokens if lists get exotic
        var prompt = ""
        for word in words where prompt.count + word.count + 2 <= 600 { prompt += prompt.isEmpty ? word : ", " + word }
        if !prompt.isEmpty { fields.append(("prompt", prompt)) }
        if provider == .openai {
            fields += words.prefix(100).map { ("keywords[]", $0) }
        }
        return fields
    }

    /// 16-bit PCM WAV: accepted everywhere, ~1.9 MB a minute at 16 kHz mono.
    static func wav(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        for sample in samples {
            let clamped = sample.isFinite ? max(-1, min(1, sample)) : 0
            append(Int16(clamped * Float(Int16.max)))
        }
        return data
    }

    static func multipart(boundary: String, fields: [(String, String)], file: Data, filename: String, mime: String) -> Data {
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
