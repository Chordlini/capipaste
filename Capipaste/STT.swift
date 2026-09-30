import AVFoundation
import FluidAudio
import Speech

enum SpeechModel: String, CaseIterable, Identifiable {
    case unified, nemotron, parakeet, cohere, apple, openai, groq

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unified: "Parakeet Unified 0.6B"
        case .nemotron: "Nemotron 3.5 Streaming"
        case .parakeet: "Parakeet 110M"
        case .cohere: "Cohere Transcribe"
        case .apple: "Apple Speech"
        case .openai: "OpenAI (your key)"
        case .groq: "Groq (your key)"
        }
    }

    /// Cloud models send the finished take to the provider; live text still comes from a model on this Mac.
    var cloud: Cloud.Provider? {
        switch self {
        case .openai: .openai
        case .groq: .groq
        default: nil
        }
    }

    var subtitle: String {
        switch self {
        case .unified: "Most accurate English, live text"
        case .nemotron: "Live text while you talk"
        case .parakeet: "Fastest, English only"
        case .cohere: "14 languages, slower"
        case .apple: "Built in, no download"
        case .openai: "gpt-transcribe · audio goes to OpenAI"
        case .groq: "Whisper large v3 turbo · audio goes to Groq"
        }
    }

    var chip: String {
        switch self {
        case .unified: "Parakeet Unified"
        case .nemotron: "Nemotron 3.5"
        case .parakeet: "Parakeet 110M"
        case .cohere: "Cohere"
        case .apple: "Apple Speech"
        case .openai: "OpenAI"
        case .groq: "Groq"
        }
    }

    var downloadHint: String {
        switch self {
        case .unified: "Download ~600 MB"
        case .nemotron: "Download ~1 GB"
        case .parakeet: "Download ~450 MB"
        case .cohere: "Download 1.8 GB"
        case .apple: ""
        case .openai, .groq: "Add key"
        }
    }

    /// Where FluidAudio keeps each model; deleting this folder removes the model.
    var folder: URL? {
        let base = STT.modelsBase
        switch self {
        case .unified: return base.appendingPathComponent(Repo.parakeetUnified.folderName)
        case .nemotron: return base.appendingPathComponent(Repo.nemotronMultilingual.folderName)
        case .parakeet: return AsrModels.defaultCacheDirectory(for: .tdtCtc110m)
        case .cohere: return base.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName)
        case .apple, .openai, .groq: return nil
        }
    }
}

/// Model catalog (download / delete / select) plus one transcription session at a time.
@MainActor @Observable
final class STT {
    nonisolated static let modelsBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    // Nemotron's "latin" build (en/es/fr/de/it/pt), 1120 ms chunks keep punctuation (FluidAudio #687).
    nonisolated static let nemotronLanguage = "en-US"
    nonisolated static let nemotronChunkMs = 1120

    var active: SpeechModel {
        didSet {
            UserDefaults.standard.set(active.rawValue, forKey: "model")
            Task { await warmUp() }
        }
    }
    private(set) var downloaded: Set<SpeechModel>
    private(set) var progress: [SpeechModel: Double] = [:]
    private(set) var diskSize: [SpeechModel: Int64] = [:]
    private(set) var problem: String?
    /// Last cloud failure (the take still went through on this Mac).
    private(set) var cloudProblem: String?
    /// Latest live transcript for the running session.
    private(set) var live = ""
    /// Extra words for this take, e.g. names read off the screenshot.
    var sessionWords: [String] = [] {
        didSet { enqueue { await self.engine.setVocabulary(Vocabulary.words + self.sessionWords) } }
    }

    private func spell(_ text: String) -> String {
        Vocabulary.apply(text, words: Vocabulary.words + sessionWords, replacements: Vocabulary.replacements)
    }

    private let engine = Engine()
    private var queue: Task<Void, Never>?

    init() {
        active = SpeechModel(rawValue: UserDefaults.standard.string(forKey: "model") ?? "") ?? .nemotron
        let saved = UserDefaults.standard.stringArray(forKey: "downloaded") ?? []
        // A model folder deleted behind our back isn't downloaded any more: fall back instead of failing every take.
        downloaded = Set(saved.compactMap(SpeechModel.init).filter { model in
            model.folder.map { FileManager.default.fileExists(atPath: $0.path) } ?? true
        })
        downloaded.forEach(refreshSize)
    }

    /// Falls back to Apple's built-in model until the chosen one is on disk (or has a key).
    var inUse: SpeechModel { isReady(active) ? active : .apple }

    func isReady(_ model: SpeechModel) -> Bool {
        if let cloud = model.cloud { return keys.contains(cloud) }
        return model == .apple || downloaded.contains(model)
    }

    /// Providers with a key in the Keychain; `keysChanged()` after editing them.
    private(set) var keys = Set(Cloud.Provider.allCases.filter { Cloud.key(for: $0) != nil })

    func keysChanged() {
        keys = Set(Cloud.Provider.allCases.filter { Cloud.key(for: $0) != nil })
        Task { await warmUp() }
    }

    /// The on-device model that shows live text while a cloud model is chosen, and takes over if the upload fails.
    var local: SpeechModel {
        guard inUse.cloud != nil else { return inUse }
        return [.unified, .nemotron, .parakeet, .cohere].first { downloaded.contains($0) } ?? .apple
    }

    // MARK: Catalog

    func download(_ model: SpeechModel) {
        guard model != .apple, model.cloud == nil, progress[model] == nil else { return }
        progress[model] = 0
        problem = nil
        let report: ProgressHandler = { p in
            Task { @MainActor in self.progress[model] = p.fractionCompleted }
        }
        Task {
            do {
                switch model {
                case .unified:
                    // Downloads the streaming encoder + decoder, then loads it (the Engine picks it up below).
                    try await StreamingUnifiedAsrManager().loadModels(to: Self.modelsBase, progressHandler: report)
                case .nemotron:
                    _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                        languageCode: Self.nemotronLanguage, chunkMs: Self.nemotronChunkMs,
                        to: Self.modelsBase, progressHandler: report)
                case .parakeet:
                    _ = try await AsrModels.download(version: .tdtCtc110m, progressHandler: report)
                case .cohere:
                    try await ModelHub.download(.cohereTranscribeCoreml, to: Self.modelsBase, progressHandler: report)
                case .apple, .openai, .groq:
                    break
                }
                downloaded.insert(model)
                saveDownloaded()
                refreshSize(model)
                if model == active { await warmUp() }
            } catch {
                problem = "\(model.title) download failed: \(error.localizedDescription)"
            }
            progress[model] = nil
        }
    }

    func delete(_ model: SpeechModel) {
        guard let folder = model.folder else { return }
        try? FileManager.default.removeItem(at: folder)
        downloaded.remove(model)
        diskSize[model] = nil
        saveDownloaded()
        Task { await engine.unload(model) }
    }

    func warmUp() async {
        let model = local
        do { try await engine.load(model) } catch { problem = "\(model.title) failed to load: \(error.localizedDescription)" }
    }

    private func saveDownloaded() {
        UserDefaults.standard.set(downloaded.map(\.rawValue), forKey: "downloaded")
    }

    private func refreshSize(_ model: SpeechModel) {
        guard let folder = model.folder,
              let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        diskSize[model] = total
    }

    // MARK: Session (calls run strictly in order)

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task {
            await previous?.value
            await work()
        }
    }

    func begin() {
        sessionWords = []
        let model = local
        enqueue {
            // Reset here, in turn: a take still finishing ahead of this one must not see it cleared.
            self.live = ""
            do { try await self.engine.begin(model, words: Vocabulary.words) } catch {
                trace("stt: \(model) failed to start: \(error), using Apple Speech for this take")
                self.problem = "\(model.title) failed to start: \(error.localizedDescription)"
                try? await self.engine.begin(.apple, words: Vocabulary.words)
            }
        }
    }

    func feed(_ samples: [Float]) {
        enqueue {
            if let text = await self.engine.feed(samples) { self.live = self.spell(text) }
        }
    }

    struct Take {
        /// Nil when both attempts failed, or came back empty although speech was heard (ask for a repeat).
        let text: String?
        /// 16 kHz mono, for Recordings.
        let audio: [Float]
    }

    /// Final transcript, retried once. Runs in turn with the other session calls, after the queued audio,
    /// so a take that starts meanwhile waits for this one instead of clearing it.
    func finish(expectSpeech: Bool) async -> Take {
        await withCheckedContinuation { done in
            enqueue { done.resume(returning: await self.settle(expectSpeech: expectSpeech)) }
        }
    }

    private func settle(expectSpeech: Bool) async -> Take {
        await engine.stop()
        let audio = await engine.audio
        return Take(text: await text(of: audio, expectSpeech: expectSpeech), audio: audio)
    }

    private func text(of audio: [Float], expectSpeech: Bool) async -> String? {
        if let cloud = inUse.cloud, let text = await transcribe(audio, with: cloud, expectSpeech: expectSpeech) {
            await engine.cancel()
            live = spell(text)
            return live
        }
        let model = local
        for attempt in 1...2 {
            do {
                let began = Date()
                let text = try await engine.transcribe(retry: attempt > 1)
                let ms = Int(Date().timeIntervalSince(began) * 1000)
                trace("stt: \(model) attempt \(attempt) -> \(text.count) chars in \(ms) ms")
                if !text.isEmpty || !expectSpeech {
                    await engine.cancel()
                    live = spell(text)
                    return live
                }
            } catch {
                trace("stt: \(model) attempt \(attempt) failed: \(error)")
            }
        }
        await engine.cancel()
        return nil
    }

    func cancel() {
        enqueue { await self.engine.cancel() }
    }

    /// The take through the provider. Nil hands it to the on-device model: offline, bad key, rate limit, timeout.
    private func transcribe(_ audio: [Float], with cloud: Cloud.Provider, expectSpeech: Bool) async -> String? {
        guard audio.count >= 8_000 else { return expectSpeech ? nil : "" } // under half a second: nothing to send
        let began = Date()
        do {
            let text = try await Cloud.transcribe(audio, with: cloud, words: Vocabulary.words + sessionWords)
            trace("stt: \(cloud) -> \(text.count) chars in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
            if text.isEmpty, expectSpeech { return nil }
            cloudProblem = nil
            return text
        } catch {
            trace("stt: \(cloud) failed after \(Int(Date().timeIntervalSince(began) * 1000)) ms: \(error), using \(local)")
            cloudProblem = "\(cloud.title): \(error.localizedDescription) Used \(local.title) instead."
            return nil
        }
    }
}

/// Owns the loaded models; one session at a time.
private actor Engine {
    private var unified: StreamingUnifiedAsrManager?
    private var nemotron: StreamingNemotronMultilingualAsrManager?
    private var parakeet: AsrManager?
    private var cohere: CoherePipeline.LoadedModels?
    private let coherePipeline = CoherePipeline()

    private var model: SpeechModel = .apple
    private var samples: [Float] = []
    private var lastLiveCount = 0
    private var running = false

    private var loadTask: Task<Void, Error>?

    /// Loads take turns. Without that, the launch warm-up and the first take both saw no model, both loaded one,
    /// and the slower load replaced the manager mid-take: the start of that note was lost.
    func load(_ model: SpeechModel) async throws {
        let previous = loadTask
        let task = Task {
            _ = try? await previous?.value
            try await self.loadNow(model)
        }
        loadTask = task
        try await task.value
    }

    private func loadNow(_ model: SpeechModel) async throws {
        // Keep only one big model in memory.
        for other in SpeechModel.allCases where other != model { await unload(other) }
        switch model {
        case .unified where unified == nil:
            let manager = StreamingUnifiedAsrManager()
            try await manager.loadModels(from: STT.modelsBase.appendingPathComponent(Repo.parakeetUnified.folderName))
            unified = manager
        case .nemotron where nemotron == nil:
            let dir = STT.modelsBase
                .appendingPathComponent(Repo.nemotronMultilingual.folderName)
                .appendingPathComponent(StreamingNemotronMultilingualAsrManager.languageDirectory(for: STT.nemotronLanguage))
                .appendingPathComponent("\(STT.nemotronChunkMs)ms")
            let manager = StreamingNemotronMultilingualAsrManager()
            try await manager.loadModels(from: dir)
            await manager.setLanguage(STT.nemotronLanguage)
            nemotron = manager
        case .parakeet where parakeet == nil:
            let models = try await AsrModels.downloadAndLoad(version: .tdtCtc110m)
            let manager = AsrManager()
            try await manager.loadModels(models)
            parakeet = manager
        case .cohere where cohere == nil:
            let dir = STT.modelsBase.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName)
            cohere = try await CoherePipeline.loadModels(encoderDir: dir, decoderDir: dir, vocabDir: dir)
        default:
            break
        }
    }

    func unload(_ model: SpeechModel) async {
        switch model {
        case .unified: await unified?.cleanup(); unified = nil
        case .nemotron: await nemotron?.cleanup(); nemotron = nil
        case .parakeet: parakeet = nil
        case .cohere: cohere = nil
        case .apple, .openai, .groq: break
        }
    }

    func begin(_ model: SpeechModel, words: [String]) async throws {
        try await load(model)
        await setVocabulary(words)
        await nemotron?.reset()
        await leadIn()
        try? await unified?.reset()
        self.model = model
        samples = []
        lastLiveCount = 0
        running = true
    }

    /// Returns updated live text when the model can provide it.
    func feed(_ chunk: [Float]) async -> String? {
        guard running else { return nil }
        samples += chunk
        switch model {
        case .unified:
            guard let unified, (try? await Self.append(chunk, to: unified)) != nil else { return nil }
            try? await unified.processBufferedAudio()
            return await unified.getPartialTranscript()
        case .nemotron:
            guard let nemotron else { return nil }
            _ = try? await nemotron.process(samples: chunk)
            return await nemotron.getPartialTranscript()
        case .parakeet:
            // ponytail: re-transcribes the whole clip every 1.5 s, so live text stops after 90 s (the final pass
            // still reads it all); windowed decode if long takes matter
            guard samples.count - lastLiveCount >= 24_000, samples.count <= 16_000 * 90 else { return nil }
            lastLiveCount = samples.count
            return try? await transcribeParakeet()
        default:
            return nil
        }
    }

    /// Nudges Nemotron toward these spellings while it decodes (other models get the text fix only).
    func setVocabulary(_ words: [String]) async {
        await nemotron?.setCustomVocabulary(words.map { CustomVocabularyTerm(text: $0) })
    }

    /// Nemotron drops a first word that starts on the very first sample (you talk the instant the key goes
    /// down); a moment of silence ahead of the take gives it a run-up. Not part of the saved audio.
    private func leadIn() async {
        _ = try? await nemotron?.process(samples: [Float](repeating: 0, count: 4_800))
    }

    /// Stops taking audio; the clip stays around for `transcribe` until `cancel`.
    func stop() { running = false }

    var audio: [Float] { samples }

    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private static func append(_ chunk: [Float], to manager: StreamingUnifiedAsrManager) async throws {
        guard !chunk.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count)) else { return }
        chunk.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        buffer.frameLength = AVAudioFrameCount(chunk.count)
        try await manager.appendAudio(buffer)
    }

    func transcribe(retry: Bool) async throws -> String {
        let text: String
        switch model {
        case .unified:
            guard let unified else { throw EngineError.notLoaded }
            if retry {
                try await unified.reset()
                try await Self.append(samples, to: unified)
            }
            text = try await unified.finish()
            try await unified.reset()
        case .nemotron:
            guard let nemotron else { throw EngineError.notLoaded }
            if retry {
                // The streaming state was consumed by the first try: replay the whole clip.
                await nemotron.reset()
                await leadIn()
                _ = try await nemotron.process(samples: samples)
            }
            text = try await nemotron.finish()
            await nemotron.reset()
        case .parakeet:
            text = try await transcribeParakeet()
        case .cohere:
            guard let cohere else { throw EngineError.notLoaded }
            text = try await coherePipeline.transcribeLong(audio: samples, models: cohere, language: .english).text
        case .apple, .openai, .groq:
            text = try await transcribeApple()
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        running = false
        samples = []
        await nemotron?.reset()
        try? await unified?.reset()
    }

    enum EngineError: Error { case notLoaded, appleModelUnavailable }

    private func transcribeParakeet() async throws -> String {
        guard let parakeet, samples.count >= 16_000 else { return "" }
        var state = TdtDecoderState.make(decoderLayers: AsrModelVersion.tdtCtc110m.decoderLayers)
        return try await parakeet.transcribe(samples, decoderState: &state).text
    }

    private func transcribeApple() async throws -> String {
        guard samples.count >= 8_000 else { return "" }
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            // First use downloads Apple's model; offline that would hang the note, so give up after 20 s.
            let done = await withTimeout(seconds: 20) { try await install.downloadAndInstall(); return true }
            guard done == true else { throw EngineError.appleModelUnavailable }
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capipaste-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            try file.write(from: buffer)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task {
            var text = ""
            for try await result in transcriber.results { text += String(result.text.characters) }
            return text
        }
        let input = try AVAudioFile(forReading: url)
        if let end = try await analyzer.analyzeSequence(from: input) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value
    }
}
