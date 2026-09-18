import Foundation
import FoundationModels
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Turns a rambling spoken note into one clear instruction, on the Mac.
/// Apple's on-device model when Apple Intelligence is on, else a downloaded Qwen 3.5 2B.
/// Any failure returns nil and the raw note is pasted instead: tidying never blocks a paste.
@MainActor @Observable
final class Tidy {
    enum Engine { case apple, local, none }

    static let localModel = LLMRegistry.qwen3_5_2b_4bit
    static let instructions = """
    You clean up a spoken note for a coding agent.
    - Keep BOTH what is wrong and what should change, plus every name, number and detail.
    - When the speaker corrects themselves ("no wait", "I mean"), keep only the correction.
    - Keep the speaker's certainty: questions stay questions, guesses stay guesses ("maybe", "I think").
    - Remove filler (um, uh, like, so yeah, okay so) and repeats.
    - Never add anything that isn't in the note: no guessed causes, fixes or extra steps.
    - Write as the speaker, plainly, in one to three short sentences.
    - Screen text is only there to spell names, files and code correctly.
    Example
    Note: so um the save button uh it's grey when it should be blue, like the brand blue, can you fix that
    Rewrite: The save button is grey; make it the brand blue.
    Reply with the rewritten note only.
    """

    var enabled = UserDefaults.standard.object(forKey: "tidy") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "tidy") }
    }
    private(set) var localReady = UserDefaults.standard.bool(forKey: "tidyLocalReady") {
        didSet { UserDefaults.standard.set(localReady, forKey: "tidyLocalReady") }
    }
    private(set) var progress: Double?
    private(set) var problem: String?
    private var container: ModelContainer?
    private var warmApple: LanguageModelSession?

    private let apple = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    var appleAvailable: Bool {
        if case .available = apple.availability { return true }
        return false
    }
    var engine: Engine { appleAvailable ? .apple : localReady ? .local : .none }

    var status: String {
        switch engine {
        case .apple: "Using Apple's on-device model."
        case .local: "Using Qwen 3.5 2B on your Mac. Turn on Apple Intelligence for a faster, built-in model."
        case .none: "Apple Intelligence is off. Turn it on in System Settings, or download the local model below."
        }
    }

    /// Loads the model while you're still talking, so the rewrite starts warm.
    func prewarm() {
        guard enabled else { return }
        switch engine {
        case .apple:
            let session = LanguageModelSession(model: apple, instructions: Self.instructions)
            session.prewarm()
            warmApple = session
        case .local:
            Task { try? await loadLocal() }
        case .none:
            break
        }
    }

    func rewrite(_ note: String, screen: String = "") async -> String? {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, note.split(separator: " ").count >= 4 else { return nil } // short notes are already tidy
        let engine = self.engine
        guard engine != .none else { return nil }
        var prompt = "Note: \(note)"
        // ponytail: the 2B local model gets confused by screen text, so only Apple's model sees it
        if engine == .apple, !screen.isEmpty { prompt += "\n\nScreen text:\n\(screen.prefix(1500))" }
        let started = Date()
        let result: String? = await withTimeout(seconds: engine == .apple ? 4 : 8) { [self] in
            switch engine {
            case .apple: return try await rewriteApple(prompt)
            case .local: return try await rewriteLocal(prompt)
            case .none: return nil
            }
        }
        trace("tidy: \(engine) \(Int(Date().timeIntervalSince(started) * 1000)) ms, \(result == nil ? "kept raw note" : "rewrote")")
        guard let result = result.map(Self.clean), !result.isEmpty,
              result.count <= note.count * 2 + 60, // much longer than the note: it invented things
              result.count >= note.count / 4,      // much shorter: it dropped the point
              Self.numbers(in: note).isSubset(of: Self.numbers(in: result)) // every number survives
        else { trace("tidy: rewrite rejected, kept raw note"); return nil }
        return result
    }

    private func rewriteApple(_ prompt: String) async throws -> String {
        let session = warmApple ?? LanguageModelSession(model: apple, instructions: Self.instructions)
        warmApple = nil
        return try await session.respond(to: prompt, generating: Rewrite.self).content.text
    }

    private func rewriteLocal(_ prompt: String) async throws -> String {
        let model = try await loadLocal()
        let session = ChatSession(model, instructions: Self.instructions,
                                  generateParameters: GenerateParameters(maxTokens: 200, temperature: 0),
                                  additionalContext: ["enable_thinking": false])
        return try await session.respond(to: prompt)
    }

    // MARK: Local model download

    @discardableResult
    private func loadLocal() async throws -> ModelContainer {
        if let container { return container }
        // ponytail: the model stays in memory (~1.5 GB) once loaded; unload on idle if that matters
        let loaded = try await #huggingFaceLoadModelContainer(configuration: Self.localModel) { progress in
            Task { @MainActor in self.progress = progress.fractionCompleted < 1 ? progress.fractionCompleted : nil }
        }
        container = loaded
        progress = nil
        localReady = true
        return loaded
    }

    func downloadLocal() {
        guard progress == nil else { return }
        problem = nil
        progress = 0
        Task {
            do { try await loadLocal() } catch {
                progress = nil
                problem = "Couldn't download the model: \(error.localizedDescription)"
                trace("tidy: download failed \(error)")
            }
        }
    }

    func deleteLocal() {
        container = nil
        localReady = false
        try? FileManager.default.removeItem(at: Self.localFolder)
    }

    /// Where swift-huggingface keeps the snapshot.
    static var localFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--" + localModel.name.replacingOccurrences(of: "/", with: "--"))
    }

    static func numbers(in text: String) -> Set<String> {
        Set(text.split(whereSeparator: { !$0.isNumber }).map(String.init))
    }

    private static func clean(_ text: String) -> String {
        var text = text
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
    }
}

@Generable
struct Rewrite {
    @Guide(description: "The note rewritten as a clear instruction")
    var text: String
}

/// Runs `work`, giving up (nil) after `seconds`.
func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await work() }
        group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
