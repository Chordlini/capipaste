// Run: swiftc Capipaste/Cloud.swift checks/cloud/main.swift -o /tmp/cloud-check && /tmp/cloud-check
// Provider requests without the network: a stub answers, and the keys go to a throwaway Keychain entry.
import Foundation

final class Stub: URLProtocol {
    nonisolated(unsafe) static var reply: (status: Int, body: String)? = (200, "{}")
    nonisolated(unsafe) static var seen: URLRequest?
    nonisolated(unsafe) static var seenBody = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Stub.seen = request
        if let stream = request.httpBodyStream {
            stream.open(); var bytes = [UInt8](repeating: 0, count: 65_536); var body = Data()
            while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; body.append(bytes, count: n) }
            Stub.seenBody = body
        }
        guard let reply = Stub.reply else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func expect(_ failure: Cloud.Failure, _ work: () async throws -> Void) async {
    do { try await work(); assertionFailure("want \(failure), got success") } catch {
        assert(error as? Cloud.Failure == failure, "want \(failure), got \(error)")
    }
}

Cloud.keychainService = "com.chordlini.capipaste.check-\(UUID().uuidString)"
let config = URLSessionConfiguration.ephemeral
config.protocolClasses = [Stub.self]
Cloud.session = URLSession(configuration: config)
defer { Cloud.Provider.allCases.forEach { Cloud.setKey(nil, for: $0) } }

// WAV header and clamping
let wav = Cloud.wav([0, 1, -1, 2, .nan])
assert(wav.count == 44 + 10 && String(data: wav[0..<4], encoding: .ascii) == "RIFF" && String(data: wav[8..<12], encoding: .ascii) == "WAVE")
let pcm = wav[44...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
assert(pcm == [0, 32767, -32767, 32767, 0], "clamps and zeroes NaN: \(pcm)")
assert(Cloud.wav([]).count == 44)
print("wav ok")

// Error mapping never needs the network
assert(Cloud.failure(status: 200, body: Data()) == nil)
assert(Cloud.failure(status: 401, body: Data()) == .badKey)
assert(Cloud.failure(status: 413, body: Data()) == .tooLarge)
assert(Cloud.failure(status: 429, body: Data()) == .rateLimited)
assert(Cloud.failure(status: 500, body: Data(#"{"error":{"message":"boom"}}"#.utf8)) == .server(500, "boom"))
assert(Cloud.failure(status: 502, body: Data("<html>".utf8)) == .server(502, ""))
print("errors ok")

assert(Cloud.cleaned(" [BLANK_AUDIO] ") == "")
assert(Cloud.cleaned("fix the header (music) please *coughs* now") == "fix the header please now")
assert(Cloud.cleaned("call foo(bar) with [1, 2] [Music]") == "call foo(bar) with [1, 2]")
print("cleanup ok")

// Keys: saved, trimmed, removed
assert(Cloud.key(for: .groq) == nil)
assert(Cloud.setKey("  gsk_test \n", for: .groq))
assert(Cloud.key(for: .groq) == "gsk_test")
Cloud.setKey("", for: .groq)
assert(Cloud.key(for: .groq) == nil)
print("keychain ok")

let tone = (0..<16_000).map { Float(sin(Double($0) * 0.1) * 0.2) }
await expect(.noKey) { _ = try await Cloud.transcribe(tone, with: .openai) }
Cloud.setKey("sk-test", for: .openai)
Cloud.setKey("gsk-test", for: .groq)

Stub.reply = (200, #"{"text":"  the save button is grey \n"}"#)
let text = try! await Cloud.transcribe(tone, with: .groq, words: ["Supabase", "useEffect"])
assert(text == "the save button is grey")
assert(Stub.seen?.url?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions", "\(Stub.seen?.url as Any)")
assert(Stub.seen?.value(forHTTPHeaderField: "Authorization") == "Bearer gsk-test")
let sent = String(decoding: Stub.seenBody, as: UTF8.self)
assert(sent.contains("name=\"model\"\r\n\r\nwhisper-large-v3-turbo") && sent.contains("Supabase, useEffect") && sent.contains("filename=\"note.wav\""))
assert(!sent.contains("keywords[]"), "Whisper has no keywords field")
print("transcribe ok")

// Spelling hints: deduped, stripped of characters the API refuses, prompt capped, keywords for OpenAI only
let many = (0..<400).map { "Word\($0)" }
let openaiFields = Cloud.speechFields(.openai, words: ["Supabase", "supabase", "use<Effect>", "a\nb", ""] + many)
let prompt = openaiFields.first { $0.0 == "prompt" }!.1
assert(prompt.hasPrefix("Supabase, useEffect, ab, Word0") && prompt.count <= 600, prompt)
assert(openaiFields.filter { $0.0 == "keywords[]" }.count == 100)
assert(Cloud.speechFields(.groq, words: []).map(\.0) == ["model", "response_format"])
print("hints ok")

Stub.reply = (401, #"{"error":{"message":"Invalid API Key"}}"#)
await expect(.badKey) { _ = try await Cloud.transcribe(tone, with: .openai) }
Stub.reply = (429, "{}")
await expect(.rateLimited) { _ = try await Cloud.transcribe(tone, with: .openai) }
Stub.reply = (200, "not json")
await expect(.unreadable) { _ = try await Cloud.transcribe(tone, with: .openai) }
Stub.reply = nil
await expect(.offline) { _ = try await Cloud.transcribe(tone, with: .openai) }
// 12 minutes won't upload: refused before sending anything
Stub.seen = nil
await expect(.tooLarge) { _ = try await Cloud.transcribe([Float](repeating: 0, count: 16_000 * 60 * 14), with: .openai) }
assert(Stub.seen == nil, "an oversized take never leaves the Mac")
print("failures ok")

Stub.reply = (200, #"{"choices":[{"message":{"role":"assistant","content":" Make the save button blue. "}}]}"#)
let tidy = try! await Cloud.chat(system: "s", user: "u", with: .openai)
assert(tidy == "Make the save button blue.")
assert(Stub.seen?.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
let chatBody = try! JSONSerialization.jsonObject(with: Stub.seenBody) as! [String: Any]
assert(chatBody["model"] as? String == "gpt-6-luna" && chatBody["reasoning_effort"] as? String == "none")
Stub.reply = (200, #"{"choices":[]}"#)
await expect(.unreadable) { _ = try await Cloud.chat(system: "s", user: "u", with: .openai) }
print("chat ok")

Stub.reply = (200, #"{"data":[]}"#)
try! await Cloud.verify(" sk-new ", with: .openai)
assert(Stub.seen?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-new")
Stub.reply = (401, "{}")
await expect(.badKey) { try await Cloud.verify("sk-bad", with: .openai) }
print("verify ok")
