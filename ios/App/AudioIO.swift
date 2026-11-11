import AVFoundation
import MediaPlayer
import VoiceCloneCore

/// Plays audio chunks as they are produced, so the first sound comes before the whole text is synthesised.
final class StreamPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioDsp.sampleRate), channels: 1, interleaved: false)!
    private let pending = DispatchGroup()
    private var running = false

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
        node.play()
        running = true
    }

    func append(_ audio: [Float]) {
        guard running, !audio.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(audio.count)
        audio.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: audio.count)
        }
        pending.enter()
        node.scheduleBuffer(buffer) { [pending] in pending.leave() }
    }

    /// Waits until everything that was appended has been played.
    func finish() async {
        await withCheckedContinuation { continuation in pending.notify(queue: .main) { continuation.resume() } }
        stop()
    }

    func stop() {
        guard running else { return }
        running = false
        node.stop(); engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Plays a saved WAV with seek, pause and lock-screen / headphone controls. Playback continues in the background
/// (the app declares the audio background mode).
final class PlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var title = "VoiceClone"
    private var commandsReady = false

    func load(_ url: URL, title: String) throws {
        stop()
        self.title = title
        let loaded = try AVAudioPlayer(contentsOf: url)
        loaded.delegate = self
        loaded.prepareToPlay()
        player = loaded
        duration = loaded.duration
        position = 0
        setupCommands()
        publishNowPlaying()
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { return }
        if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
        player.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            self.position = player.currentTime
            self.publishNowPlaying()
        }
        publishNowPlaying()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        publishNowPlaying()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(player.duration, time))
        position = player.currentTime
        publishNowPlaying()
    }

    func skip(_ seconds: TimeInterval) { seek(to: position + seconds) }

    func stop() {
        timer?.invalidate()
        player?.stop()
        player = nil
        isPlaying = false
        position = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        timer?.invalidate()
        isPlaying = false
        position = 0
        player.currentTime = 0
        publishNowPlaying()
    }

    private func publishNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "VoiceClone",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }

    private func setupCommands() {
        if commandsReady { return }
        commandsReady = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in self?.skip(10); return .success }
        center.skipBackwardCommand.addTarget { [weak self] _ in self?.skip(-10); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime); return .success
        }
    }
}

/// Records from the microphone and returns mono 48 kHz audio.
final class MicRecorder: ObservableObject {
    @Published private(set) var seconds: Double = 0
    @Published private(set) var level: Float = 0
    private let engine = AVAudioEngine()
    private var samples = [Float]()
    private var sourceRate = 48000.0
    private let lock = NSLock()
    private(set) var isRecording = false

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        samples.removeAll()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        sourceRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            let chunk = Array(UnsafeBufferPointer(start: channel, count: count))
            let rms = (chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, count))).squareRoot()
            self.lock.lock(); self.samples.append(contentsOf: chunk); let total = self.samples.count; self.lock.unlock()
            DispatchQueue.main.async { self.level = min(1, rms * 6); self.seconds = Double(total) / self.sourceRate }
        }
        try engine.start()
        isRecording = true
    }

    /// Stops and returns the recording at 48 kHz.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        lock.lock(); let recorded = samples; samples.removeAll(); lock.unlock()
        DispatchQueue.main.async { self.level = 0 }
        return AudioDsp.resample(recorded, from: Int(sourceRate))
    }
}

/// Reads any audio file the system can decode into mono 48 kHz samples (at most the first 120 seconds).
enum AudioFileLoader {
    static let maxSeconds = 120.0

    static func load(_ url: URL) throws -> [Float] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioDsp.sampleRate), channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { throw EngineError.message("この音声ファイルは読み込めません") }
        let inputFrames = AVAudioFrameCount(min(Double(file.length), maxSeconds * file.processingFormat.sampleRate))
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inputFrames) else { throw EngineError.message("この音声ファイルは読み込めません") }
        try file.read(into: input, frameCount: inputFrames)
        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw EngineError.message("この音声ファイルは読み込めません") }
        var supplied = false
        var failure: NSError?
        converter.convert(to: output, error: &failure) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        if let failure { throw failure }
        guard let channel = output.floatChannelData?[0], output.frameLength > 0 else { throw EngineError.message("音声が含まれていないようです") }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
