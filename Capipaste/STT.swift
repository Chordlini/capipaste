import AVFoundation
import FluidAudio
import Speech

enum SpeechModel: String, CaseIterable, Identifiable {
    case nemotron, parakeet, cohere, apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nemotron: "Nemotron 3.5 Streaming"
        case .parakeet: "Parakeet 110M"
        case .cohere: "Cohere Transcribe"
        case .apple: "Apple Speech"
        }
    }

    var subtitle: String {
        switch self {
        case .nemotron: "Live text while you talk"
        case .parakeet: "Fastest, English only"
        case .cohere: "Most accurate, slower"
        case .apple: "Built in, no download"
        }
    }

    var chip: String {
        switch self {
        case .nemotron: "Nemotron 3.5"
        case .parakeet: "Parakeet 110M"
        case .cohere: "Cohere"
        case .apple: "Apple Speech"
        }
    }

    var downloadHint: String {
        switch self {
        case .nemotron: "Download ~1 GB"
        case .parakeet: "Download ~450 MB"
        case .cohere: "Download 1.8 GB"
        case .apple: ""
        }
    }

    /// Where FluidAudio keeps each model; deleting this folder removes the model.
    var folder: URL? {
        let base = STT.modelsBase
        switch self {
        case .nemotron: return base.appendingPathComponent(Repo.nemotronMultilingual.folderName)
        case .parakeet: return AsrModels.defaultCacheDirectory(for: .tdtCtc110m)
        case .cohere: return base.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName)
        case .apple: return nil
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
    /// Latest live transcript for the running session.
    private(set) var live = ""

    private let engine = Engine()
    private var queue: Task<Void, Never>?

    init() {
        active = SpeechModel(rawValue: UserDefaults.standard.string(forKey: "model") ?? "") ?? .nemotron
        let saved = UserDefaults.standard.stringArray(forKey: "downloaded") ?? []
        downloaded = Set(saved.compactMap(SpeechModel.init))
        downloaded.forEach(refreshSize)
    }

    /// Falls back to Apple's built-in model until the chosen one is on disk.
    var inUse: SpeechModel { downloaded.contains(active) ? active : .apple }

    func isReady(_ model: SpeechModel) -> Bool { model == .apple || downloaded.contains(model) }

    // MARK: Catalog

    func download(_ model: SpeechModel) {
        guard model != .apple, progress[model] == nil else { return }
        progress[model] = 0
        problem = nil
        let report: ProgressHandler = { p in
            Task { @MainActor in self.progress[model] = p.fractionCompleted }
        }
        Task {
            do {
                switch model {
                case .nemotron:
                    _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                        languageCode: Self.nemotronLanguage, chunkMs: Self.nemotronChunkMs,
                        to: Self.modelsBase, progressHandler: report)
                case .parakeet:
                    _ = try await AsrModels.download(version: .tdtCtc110m, progressHandler: report)
                case .cohere:
                    try await ModelHub.download(.cohereTranscribeCoreml, to: Self.modelsBase, progressHandler: report)
                case .apple:
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
        let model = inUse
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
        live = ""
        let model = inUse
        enqueue {
            do { try await self.engine.begin(model) } catch {
                self.problem = "\(model.title) failed to start: \(error.localizedDescription)"
            }
        }
    }

    func feed(_ samples: [Float]) {
        enqueue {
            if let text = await self.engine.feed(samples) { self.live = text }
        }
    }

    /// Final transcript, retried once. Returns nil when both attempts fail, or come back empty
    /// although speech was heard, so the caller can ask for a repeat.
    func finish(expectSpeech: Bool) async -> String? {
        await queue?.value // let queued audio land first
        await engine.stop()
        let model = inUse
        for attempt in 1...2 {
            do {
                let text = try await engine.transcribe(retry: attempt > 1)
                trace("stt: \(model) attempt \(attempt) -> \(text.count) chars")
                if !text.isEmpty || !expectSpeech {
                    await engine.cancel()
                    live = text
                    return text
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
}

/// Owns the loaded models; one session at a time.
private actor Engine {
    private var nemotron: StreamingNemotronMultilingualAsrManager?
    private var parakeet: AsrManager?
    private var cohere: CoherePipeline.LoadedModels?
    private let coherePipeline = CoherePipeline()

    private var model: SpeechModel = .apple
    private var samples: [Float] = []
    private var lastLiveCount = 0
    private var running = false

    func load(_ model: SpeechModel) async throws {
        // Keep only one big model in memory.
        for other in SpeechModel.allCases where other != model { await unload(other) }
        switch model {
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
        case .nemotron: await nemotron?.cleanup(); nemotron = nil
        case .parakeet: parakeet = nil
        case .cohere: cohere = nil
        case .apple: break
        }
    }

    func begin(_ model: SpeechModel) async throws {
        try await load(model)
        await nemotron?.reset()
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
        case .nemotron:
            guard let nemotron else { return nil }
            _ = try? await nemotron.process(samples: chunk)
            return await nemotron.getPartialTranscript()
        case .parakeet:
            // ponytail: re-transcribes the whole clip every 1.5 s; fine for notes, windowed decode if clips get long
            guard samples.count - lastLiveCount >= 24_000 else { return nil }
            lastLiveCount = samples.count
            return try? await transcribeParakeet()
        default:
            return nil
        }
    }

    /// Stops taking audio; the clip stays around for `transcribe` until `cancel`.
    func stop() { running = false }

    func transcribe(retry: Bool) async throws -> String {
        let text: String
        switch model {
        case .nemotron:
            guard let nemotron else { throw EngineError.notLoaded }
            if retry {
                // The streaming state was consumed by the first try: replay the whole clip.
                await nemotron.reset()
                _ = try await nemotron.process(samples: samples)
            }
            text = try await nemotron.finish()
            await nemotron.reset()
        case .parakeet:
            text = try await transcribeParakeet()
        case .cohere:
            guard let cohere else { throw EngineError.notLoaded }
            text = try await coherePipeline.transcribeLong(audio: samples, models: cohere, language: .english).text
        case .apple:
            text = try await transcribeApple()
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        running = false
        samples = []
        await nemotron?.reset()
    }

    enum EngineError: Error { case notLoaded }

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
            try await install.downloadAndInstall()
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
