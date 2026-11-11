import Foundation

let hop = 1920
let latentSize = 32
let layerCount = 12

/// Irodori-TTS v4.1-Small MF / RF (port of the Android `IrodoriEngine` and of adapters/irodori_onnx.py):
/// ref clips -> dacvae_encode -> speaker_encoder (once);
/// text -> text_encoder -> duration -> context_kv -> dit_step x N (MF / RF+CFG) -> dacvae_decode (chunked, streamed).
/// The graphs are run through a [GraphRunner], so this logic is the same on every platform and is tested without ONNX Runtime.
public final class IrodoriEngine {
    public struct Stats {
        public var tokens = 0
        public var frames = 0
        public var textMs = 0
        public var ditMs = 0
        public var decodeMs = 0
        public var firstAudioMs = 0
        public var contextMs = 0
    }

    private let runner: GraphRunner
    private let tokenizer: UnigramTokenizer
    private let flow: FlowKind
    private let lowMemory: Bool
    private var emptyCaption: (state: [Float], length: Int)?

    public init(runner: GraphRunner, tokenizer: UnigramTokenizer, flow: FlowKind = .mf, lowMemory: Bool = false) {
        self.runner = runner; self.tokenizer = tokenizer; self.flow = flow; self.lowMemory = lowMemory
    }

    public func cancel() { runner.cancel() }

    private func done(_ graph: String) { if lowMemory { runner.release(graph) } }

    private func named(_ outputs: [NamedTensor], _ name: String) throws -> Tensor {
        guard let found = outputs.first(where: { $0.name == name }) else { throw EngineError.message("モデルの出力 \(name) が見つかりません") }
        return found.tensor
    }

    // MARK: - enrolment

    /// Turns reference recordings (mono, 48 kHz) into a voice.
    public func enroll(clips48k: [[Float]], cancelled: () -> Bool = { false }, log: (String) -> Void = { _ in }) throws -> Voice {
        var latents = [[Float]]()
        var frames = 0
        for (i, raw) in clips48k.enumerated() {
            if cancelled() { throw EngineError.cancelled }
            let wav = AudioDsp.reflectPad(AudioDsp.normalizeLoudness(raw), hop: hop)
            let outputs = try runner.run("dacvae_encode", inputs: ["waveform": .float(wav, [1, 1, wav.count])])
            guard let latent = outputs.first?.tensor else { throw EngineError.message("dacvae_encode の出力がありません") }
            latents.append(latent.floats); frames += latent.dim(1)
            log("参照 \(i + 1)/\(clips48k.count) をエンコード")
        }
        done("dacvae_encode")
        let n = min(frames, 120 * AudioDsp.sampleRate / hop) / 4 * 4 // speaker_patch_size = 4
        guard n >= 4 else { throw EngineError.message("参照音声が短すぎます") }
        var cat = [Float](repeating: 0, count: n * latentSize)
        var offset = 0
        for latent in latents {
            let k = min(latent.count, cat.count - offset)
            for i in 0..<k { cat[offset + i] = latent[i] }
            offset += k
            if offset >= cat.count { break }
        }
        let outputs = try runner.run("speaker_encoder", inputs: [
            "ref_latent": .float(cat, [1, n, latentSize]), "mask": .float([Float](repeating: 1, count: n), [1, n]),
        ])
        let state = try named(outputs, "speaker_state")
        let mask = try named(outputs, "speaker_mask")
        done("speaker_encoder")
        let seconds = Float(clips48k.reduce(0) { $0 + $1.count }) / Float(AudioDsp.sampleRate)
        return Voice(state: state.floats, len: state.dim(1), mask: mask.floats, refSeconds: seconds)
    }

    // MARK: - synthesis

    private func encodeText(_ text: String) throws -> (state: [Float], length: Int) {
        var ids = [tokenizer.bosId] + tokenizer.encode(text)
        if ids.count > 256 { ids = Array(ids.prefix(256)) }
        let l = ids.count
        let outputs = try runner.run("text_encoder", inputs: [
            "input_ids": .int64(ids.map { Int64($0) }, [1, l]), "mask": .float([Float](repeating: 1, count: l), [1, l]),
        ])
        return (try named(outputs, "text_state").floats, l)
    }

    /// The empty caption (VoiceDesign off) is masked out and constant, so it is encoded once.
    private func captionState() throws -> (state: [Float], length: Int) {
        if let cached = emptyCaption { return cached }
        let outputs = try runner.run("text_encoder", inputs: [
            "input_ids": .int64([Int64(tokenizer.bosId)], [1, 1]), "mask": .float([1], [1, 1]),
        ])
        let result = (try named(outputs, "caption_state").floats, 1)
        emptyCaption = result
        return result
    }

    /// Synthesises one sentence. Audio is delivered through [onAudio] chunk by chunk (first chunk 0.5–1 s, then 3 s) so
    /// playback can start before the whole sentence is decoded.
    public func synth(voice: Voice, text: String, steps: Int? = nil, seed: Int64 = 0, cancelled: () -> Bool = { false },
                      onAudio: ([Float]) throws -> Void) throws -> Stats {
        var stats = Stats()
        let started = Date()
        func ms(_ since: Date) -> Int { max(0, Int(Date().timeIntervalSince(since) * 1000)) }
        let steps = steps ?? (flow == .rf ? 40 : 4)
        let (caption, captionLength) = try captionState()
        let (textState, l) = try encodeText(TextPrep.normalize(text))
        done("text_encoder")
        stats.tokens = l
        stats.textMs = ms(started)

        let contextStart = Date()
        let sLen = voice.len
        var feeds: [String: Tensor] = [
            "text_state": .float(textState, [1, l, 512]), "text_mask": .float([Float](repeating: 1, count: l), [1, l]),
            "speaker_state": .float(voice.state, [1, sLen, speakerDim]), "speaker_mask": .float(voice.mask, [1, sLen]),
            "caption_state": .float(caption, [1, captionLength, 512]), "caption_mask": .float([Float](repeating: 0, count: captionLength), [1, captionLength]),
            "has_speaker": .scalar(1), "has_caption": .scalar(0),
            "speaker_kv_scales": .float([Float](repeating: 1, count: layerCount), [layerCount]),
        ]
        let durationOutputs = try runner.run("duration", inputs: feeds)
        guard let logFrames = durationOutputs.first?.tensor.floats.first else { throw EngineError.message("duration の出力がありません") }
        done("duration")
        let minFrames = Int(0.5 * Double(AudioDsp.sampleRate) / Double(hop)) + 1
        let frames = min(max(Int(expm1(Double(logFrames)).rounded()), minFrames), 30 * AudioDsp.sampleRate / hop)
        stats.frames = frames

        func conditions(_ kind: FlowCondition) throws -> [String: Tensor] {
            var f = feeds
            if kind == .noText {
                f["text_state"] = .float([Float](repeating: 0, count: textState.count), [1, l, 512])
                f["text_mask"] = .float([Float](repeating: 0, count: l), [1, l])
            }
            if kind == .noSpeaker {
                f["speaker_state"] = .float([Float](repeating: 0, count: voice.state.count), [1, sLen, speakerDim])
                f["speaker_mask"] = .float([Float](repeating: 0, count: voice.len), [1, sLen])
            }
            for kv in try runner.run("context_kv", inputs: f) { f[kv.name] = kv.tensor }
            return f
        }
        var bundles = [FlowCondition: [String: Tensor]]()
        for kind in FlowCondition.allCases where flow == .rf || kind == .full { bundles[kind] = try conditions(kind) }
        feeds.removeAll()
        done("context_kv")

        var rng = JavaRandom(seed: seed)
        let initial = (0..<(frames * latentSize)).map { _ in Float(rng.nextGaussian()) }
        stats.contextMs = ms(contextStart)
        let ditStart = Date()
        let x = try FlowSampler.sample(initial: initial, steps: steps, flow: flow, cancelled: cancelled) { current, t, delta, kind in
            if cancelled() { throw EngineError.cancelled }
            var f = bundles[kind]!
            f["x_t"] = .float(current, [1, frames, latentSize]); f["t"] = .scalar(t); f["delta_t"] = .scalar(delta)
            guard let v = try self.runner.run("dit_step", inputs: f).first?.tensor.floats else { throw EngineError.message("dit_step の出力がありません") }
            return v
        }
        done("dit_step")
        stats.ditMs = ms(ditStart)

        let keep = IrodoriEngine.flatteningPoint(x, frames: frames).map { $0 > 0 ? min(frames, $0) : frames } ?? frames
        let decodeStart = Date()
        var outputTime = 0
        try decodeChunked(x, frames: frames, keep: keep) { audio in
            if cancelled() { throw EngineError.cancelled }
            if stats.firstAudioMs == 0 { stats.firstAudioMs = max(1, ms(started)) }
            let before = Date()
            try onAudio(audio)
            outputTime += ms(before)
        }
        done("dacvae_decode")
        stats.decodeMs = max(0, ms(decodeStart) - outputTime)
        return stats
    }

    /// Latent frames (25 per second) of the successive decode chunks. Overlapping chunks with 8 frames of context
    /// reproduce a one-shot decode.
    public static let chunkFrames = [25, 75]

    private func decodeChunked(_ z: [Float], frames: Int, keep: Int, out: ([Float]) throws -> Void) throws {
        let ctx = 8
        var st = 0
        var n = 0
        var chunk = IrodoriEngine.chunkFrames[0]
        while st < keep {
            let len = min(chunk, keep - st)
            let a = max(0, st - ctx)
            let b = min(frames, st + len + ctx)
            let piece = Array(z[(a * latentSize)..<(b * latentSize)])
            let outputs = try runner.run("dacvae_decode", inputs: ["latent": .float(piece, [1, b - a, latentSize])])
            guard let y = outputs.first?.tensor.floats else { throw EngineError.message("dacvae_decode の出力がありません") }
            try out(Array(y[((st - a) * hop)..<((st - a + len) * hop)]))
            st += len
            n += 1
            chunk = IrodoriEngine.chunkFrames[min(n, IrodoriEngine.chunkFrames.count - 1)]
        }
    }

    /// Echo-style tail detection (window 20, std < 0.05, |mean| < 0.1) on the (T, 32) latent; nil when there is none.
    static func flatteningPoint(_ z: [Float], frames: Int, window: Int = 20) -> Int? {
        var padded = z
        padded.append(contentsOf: [Float](repeating: 0, count: (frames + window) * latentSize - z.count))
        let n = window * latentSize
        for i in 0..<frames {
            var s = 0.0, s2 = 0.0
            for j in (i * latentSize)..<(i * latentSize + n) { let v = Double(padded[j]); s += v; s2 += v * v }
            let mean = s / Double(n)
            let std = max(0, s2 / Double(n) - mean * mean).squareRoot()
            if std < 0.05 && abs(mean) < 0.1 { return i }
        }
        return nil
    }
}
