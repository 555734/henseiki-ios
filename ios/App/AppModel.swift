import SwiftUI
import UIKit
import VoiceCloneCore

enum ModelState: Equatable {
    case missing
    case downloading(Double, String)
    case installing(String)
    case ready
    case failed(String)
}

/// Thread-safe stop flag shared between the screens and the engine queue.
final class CancelToken {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

@MainActor
final class AppModel: ObservableObject {
    let paths = AppPaths()
    let profile = ModelProfile.mfMixed8
    let player = PlaybackController()
    let recorder = MicRecorder()
    private let defaults = UserDefaults.standard
    private let host = EngineHost()
    private let library: VoiceLibrary
    private let clipStore: ClipStore
    private var speakToken: CancelToken?
    private var downloadTask: Task<Void, Never>?

    @Published var termsAccepted: Bool
    @Published var voiceConsent: Bool
    @Published private(set) var modelState: ModelState = .missing
    @Published private(set) var voices: [VoiceLibrary.Entry] = []
    @Published private(set) var activeVoiceId: String?
    @Published var text: String { didSet { defaults.set(text, forKey: "draft_text") } }
    @Published var status = ""
    @Published private(set) var isBusy = false
    @Published private(set) var lastAudio: URL?
    @Published private(set) var lastAudioTitle = ""
    @Published private(set) var clipSeconds = 0.0
    @Published private(set) var clipCount = 0
    @Published private(set) var isRecording = false
    @Published private(set) var promptIndex: Int
    @Published var freeTalk: Bool { didSet { defaults.set(freeTalk, forKey: "record_free") } }

    init() {
        termsAccepted = UserDefaults.standard.integer(forKey: "terms_version") >= LegalTexts.version
        voiceConsent = UserDefaults.standard.bool(forKey: "voice_consent")
        text = UserDefaults.standard.string(forKey: "draft_text") ?? "こんにちは。これは、私の声をもとにスマートフォンの中だけで作った音声です。"
        freeTalk = UserDefaults.standard.object(forKey: "record_free") as? Bool ?? true
        promptIndex = UserDefaults.standard.integer(forKey: "prompt_index")
        library = VoiceLibrary(directory: paths.voices, activeFile: paths.voiceFile)
        clipStore = ClipStore(directory: paths.clips)
        refreshModelState()
        refreshVoices()
        refreshClips()
    }

    // MARK: - derived

    var voiceReady: Bool { activeVoiceId != nil }
    var modelReady: Bool { modelState == .ready }
    var canStartDownload: Bool { switch modelState { case .missing, .failed: return true; default: return false } }
    var canSpeak: Bool { modelReady && voiceReady && !isBusy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canRegister: Bool { modelReady && !isBusy && !isRecording && clipSeconds >= 3 }
    var activeVoiceName: String { voices.first { $0.id == activeVoiceId }?.name ?? "" }
    var suggestedFileName: String { SavedAudioName.make(text: lastAudioTitle) }
    var nextPrompt: String? { promptIndex < RecordingPrompts.lines.count ? RecordingPrompts.lines[promptIndex] : nil }

    // MARK: - terms

    func acceptTerms() { defaults.set(LegalTexts.version, forKey: "terms_version"); termsAccepted = true }
    func giveVoiceConsent() { defaults.set(true, forKey: "voice_consent"); voiceConsent = true }

    // MARK: - model

    func refreshModelState() {
        if case .downloading = modelState { return }
        if case .installing = modelState { return }
        modelState = ModelPack.isReady(paths.modelDirectory(profile), profile: profile) ? .ready : .missing
    }

    /// One-time download and set-up of the speech model. It continues in the background.
    func startModelDownload() {
        guard canStartDownload else { return }
        let profile = self.profile
        let paths = self.paths
        downloadTask = Task {
            do {
                modelState = .downloading(0, "配布情報を確認しています")
                let catalogURL = ModelPack.downloadURL(profile, repository: AppPaths.modelRepository, name: "download.json")
                let catalog = try ModelPack.parseCatalog(try await PublicFetch.data(from: catalogURL), profile: profile)
                let zip = paths.downloads.appendingPathComponent(profile.packName)
                let existing = ((try? FileManager.default.attributesOfItem(atPath: zip.path)[.size]) as? NSNumber)?.int64Value
                if existing != catalog.size {
                    try await BackgroundDownloader.shared.download(from: ModelPack.downloadURL(profile, repository: AppPaths.modelRepository, name: profile.packName), to: zip) { done, total in
                        Task { @MainActor in self.modelState = .downloading(total > 0 ? Double(done) / Double(total) : 0, "ダウンロード中") }
                    }
                }
                modelState = .installing("ファイルを確認しています…")
                let intact = try await Task.detached { try SHA256Hasher.hex(ofFile: zip) == catalog.sha256 }.value
                guard intact else {
                    try? FileManager.default.removeItem(at: zip)
                    throw EngineError.message("ダウンロードしたファイルが壊れていました。もう一度お試しください。")
                }
                try await Task.detached {
                    try ModelPack.install(zip: zip, root: paths.models, profile: profile, validate: AppModel.validatePack,
                                          progress: { message in Task { @MainActor in self.modelState = .installing(message) } })
                }.value
                try? FileManager.default.removeItem(at: zip)
                modelState = .missing
                refreshModelState()
                status = "準備ができました。次は、あなたの声を登録します。"
            } catch EngineError.cancelled {
                modelState = .missing
            } catch {
                modelState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelModelDownload() { BackgroundDownloader.shared.cancel(); downloadTask?.cancel() }

    /// Opens every graph of a staged pack, so a pack this device cannot run is rejected before it replaces anything.
    nonisolated static func validatePack(_ directory: URL) throws {
        let tokenizer = try UnigramTokenizer.load(directory.appendingPathComponent("tokenizer.json"))
        guard tokenizer.bosId >= 0 else { throw EngineError.message("tokenizer: BOS token required") }
        let runner = try OrtRunner(directory: directory, threads: 2)
        for name in ["text_encoder", "dit_step", "context_kv", "duration", "speaker_encoder", "dacvae_encode", "dacvae_decode"] {
            try runner.open(name); runner.release(name)
        }
    }

    // MARK: - voices

    func refreshVoices() {
        voices = library.list()
        activeVoiceId = library.activeId()
    }

    func switchVoice(_ id: String) {
        guard !isBusy, let entry = library.activate(id) else { return }
        refreshVoices()
        status = "声を「\(entry.name)」に切り替えました"
    }

    func renameVoice(_ id: String, to name: String) { library.rename(id, to: name); refreshVoices() }

    func deleteVoice(_ id: String) {
        guard !isBusy else { return }
        library.delete(id)
        refreshVoices()
    }

    // MARK: - recording and registration

    func refreshClips() { clipSeconds = clipStore.seconds(); clipCount = clipStore.list().count }

    func toggleRecording() {
        if isRecording { finishRecording(); return }
        guard !isBusy else { return }
        Task {
            guard await MicRecorder.requestPermission() else { status = "マイクの使用を許可すると録音できます（設定アプリ → VoiceClone）"; return }
            do { try recorder.start(); isRecording = true; status = "" } catch { status = "録音を始められませんでした" }
        }
    }

    private func finishRecording() {
        let audio = recorder.stop()
        isRecording = false
        guard audio.count >= AudioDsp.sampleRate / 2 else { status = "録音が短すぎます。もう一度お試しください"; return }
        do {
            try clipStore.add(audio)
            if !freeTalk { promptIndex += 1; defaults.set(promptIndex, forKey: "prompt_index") }
            refreshClips()
            status = "録音を保存しました"
        } catch { status = "録音を保存できませんでした" }
    }

    func undoLastClip() {
        guard !isBusy, !isRecording else { return }
        clipStore.removeLast()
        if !freeTalk && promptIndex > 0 { promptIndex -= 1; defaults.set(promptIndex, forKey: "prompt_index") }
        refreshClips()
    }

    func importAudioFile(_ url: URL) {
        guard !isBusy else { return }
        isBusy = true; status = "音声ファイルを読み込んでいます…"
        Task {
            defer { isBusy = false }
            do {
                let audio = try await Task.detached { try AudioFileLoader.load(url) }.value
                guard audio.count >= AudioDsp.sampleRate / 2 else { throw EngineError.message("音声が短すぎます") }
                try clipStore.add(audio)
                refreshClips()
                status = "音声ファイルを取り込みました（先頭120秒まで）"
            } catch { status = error.localizedDescription }
        }
    }

    func register() {
        guard canRegister else { return }
        isBusy = true; status = "声を登録しています…"
        let directory = paths.modelDirectory(profile), flow = profile.flow
        Task {
            defer { isBusy = false }
            do {
                let clips = try clipStore.load()
                let voice = try await host.run(directory: directory, flow: flow) { engine, _ in try engine.enroll(clips48k: clips) }
                try voice.encoded().write(to: paths.voiceFile, options: .atomic)
                library.sync(source: "registered")
                clipStore.clear(); promptIndex = 0; defaults.set(0, forKey: "prompt_index")
                refreshClips(); refreshVoices()
                status = "声を登録しました。読み上げで試せます"
            } catch { status = error.localizedDescription }
        }
    }

    // MARK: - speaking

    func speak() {
        guard canSpeak else { return }
        let sentences = TextPrep.splitSentences(text)
        guard !sentences.isEmpty else { status = "読み上げたい文章を入力してください"; return }
        player.stop()
        isBusy = true; status = "音声を作っています…"
        let token = CancelToken()
        speakToken = token
        let spoken = text
        let directory = paths.modelDirectory(profile), flow = profile.flow, steps = profile.defaultSteps
        let output = paths.cache.appendingPathComponent("speech-\(UUID().uuidString).wav")
        let voiceURL = paths.voiceFile
        let report: (String) -> Void = { message in Task { @MainActor in self.status = message } }
        Task {
            let background = UIApplication.shared.beginBackgroundTask(withName: "voiceclone-speech")
            let stream = StreamPlayer()
            var writer: WavFileWriter?
            do {
                let voice = try Voice.load(from: voiceURL)
                try stream.start()
                let wav = try WavFileWriter(url: output)
                writer = wav
                try await host.run(directory: directory, flow: flow) { engine, _ in
                    for (index, sentence) in sentences.enumerated() {
                        if token.isCancelled { throw EngineError.cancelled }
                        report("音声を生成中 \(index + 1)/\(sentences.count)")
                        _ = try engine.synth(voice: voice, text: sentence, steps: steps, seed: Int64(index), cancelled: { token.isCancelled }) { audio in
                            try wav.append(audio); stream.append(audio)
                        }
                    }
                }
                try wav.close()
                await stream.finish()
                lastAudio = output
                lastAudioTitle = String(spoken.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
                try? player.load(output, title: lastAudioTitle)
                status = "音声ができました。「聞く」で再生・保存・共有できます"
            } catch EngineError.cancelled {
                stream.stop(); try? writer?.close()
                status = "生成を停止しました"
            } catch {
                stream.stop(); try? writer?.close()
                status = error.localizedDescription
            }
            isBusy = false
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }
    }

    func stopSpeaking() { speakToken?.cancel(); host.cancel() }

    // MARK: - text files

    func importTextFile(_ url: URL) {
        Task {
            do {
                let loaded = try await Task.detached { () -> TextFileReader.Loaded in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let (data, cut) = try TextFileReader.readBytes(from: url)
                    return try TextFileReader.load(data, name: url.lastPathComponent, cut: cut)
                }.value
                text = loaded.text
                status = "「\(url.lastPathComponent)」を読み込みました（\(loaded.text.count)文字）" + (loaded.truncated ? "。長いため先頭の約\(TextFileReader.maxChars)文字までです" : "")
            } catch { status = (error as? TextFileReader.NotTextError)?.message ?? "ファイルを読み込めませんでした" }
        }
    }

    // MARK: - data

    func deleteAllData() {
        guard !isBusy, !isRecording else { return }
        player.stop()
        library.clear()
        clipStore.clear()
        try? FileManager.default.removeItem(at: paths.cache)
        try? FileManager.default.createDirectory(at: paths.cache, withIntermediateDirectories: true)
        for key in ["draft_text", "voice_consent", "prompt_index"] { defaults.removeObject(forKey: key) }
        lastAudio = nil; lastAudioTitle = ""; voiceConsent = false; promptIndex = 0
        text = "こんにちは。これは、私の声をもとにスマートフォンの中だけで作った音声です。"
        refreshVoices(); refreshClips()
        status = "録音・登録した声・生成した音声をすべて削除しました"
    }

    func deleteModel() {
        guard !isBusy else { return }
        host.unload()
        try? FileManager.default.removeItem(at: paths.modelDirectory(profile))
        modelState = .missing
        refreshModelState()
    }
}
