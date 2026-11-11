import XCTest
@testable import VoiceCloneCore

/// A stand-in for ONNX Runtime: tiny deterministic graphs with the real graphs' names and tensor shapes.
final class FakeRunner: GraphRunner {
    var calls = [String]()
    var released = [String]()
    var cancelled = false
    var frames = 60
    var dit: ((Tensor) -> [Float])?
    var inputsSeen = [String: [[String: Tensor]]]()

    func run(_ graph: String, inputs: [String: Tensor]) throws -> [NamedTensor] {
        if cancelled { throw EngineError.cancelled }
        calls.append(graph)
        inputsSeen[graph, default: []].append(inputs)
        switch graph {
        case "dacvae_encode":
            let samples = inputs["waveform"]!.shape[2]
            XCTAssertEqual(samples % 1920, 0, "the waveform must be padded to a whole number of frames")
            return [NamedTensor(name: "latent", tensor: .float([Float](repeating: 0.5, count: samples / 1920 * 32), [1, samples / 1920, 32]))]
        case "speaker_encoder":
            let n = inputs["ref_latent"]!.shape[1]
            return [NamedTensor(name: "speaker_state", tensor: .float([Float](repeating: 0.1, count: (n / 4) * speakerDim), [1, n / 4, speakerDim])),
                    NamedTensor(name: "speaker_mask", tensor: .float([Float](repeating: 1, count: n / 4), [1, n / 4]))]
        case "text_encoder":
            let l = inputs["input_ids"]!.shape[1]
            return [NamedTensor(name: "text_state", tensor: .float([Float](repeating: 0.2, count: l * 512), [1, l, 512])),
                    NamedTensor(name: "caption_state", tensor: .float([Float](repeating: 0.3, count: l * 512), [1, l, 512]))]
        case "duration":
            return [NamedTensor(name: "log_frames", tensor: .float([Float(log(Double(frames + 1)))], [1]))]
        case "context_kv":
            return [NamedTensor(name: "k0", tensor: .float([1], [1])), NamedTensor(name: "v0", tensor: .float([2], [1]))]
        case "dit_step":
            let x = inputs["x_t"]!
            return [NamedTensor(name: "v", tensor: .float(dit?(x) ?? [Float](repeating: 0, count: x.floats.count), x.shape))]
        case "dacvae_decode":
            // audio sample k carries the first channel of its latent frame, so the stitching can be checked exactly
            let z = inputs["latent"]!
            let t = z.shape[1]
            return [NamedTensor(name: "audio", tensor: .float((0..<(t * 1920)).map { z.floats[($0 / 1920) * 32] }, [1, 1, t * 1920]))]
        default:
            throw EngineError.message("unknown graph \(graph)")
        }
    }
    func release(_ graph: String) { released.append(graph) }
    func cancel() { cancelled = true }
}

final class EngineTests: XCTestCase {
    private let tokenizer = try! UnigramTokenizer.load(Fixture.url("tokenizer_synthetic.json"))
    private let voice = Voice(state: [Float](repeating: 0.1, count: 12 * speakerDim), len: 12, mask: [Float](repeating: 1, count: 12), refSeconds: 30)

    func testEnrollmentFeedsTheEncodersAndReturnsAVoice() throws {
        let runner = FakeRunner()
        let engine = IrodoriEngine(runner: runner, tokenizer: tokenizer)
        let clip = (0..<48000).map { Float(0.2 * sin(Double($0) * 0.05)) }
        let voice = try engine.enroll(clips48k: [clip, clip])
        XCTAssertEqual(runner.calls, ["dacvae_encode", "dacvae_encode", "speaker_encoder"])
        let encoderInput = runner.inputsSeen["speaker_encoder"]![0]
        XCTAssertEqual(encoderInput["ref_latent"]!.shape, [1, 48, 32]) // 2 x 25 frames, cut to a multiple of 4
        XCTAssertEqual(encoderInput["mask"]!.shape, [1, 48])
        XCTAssertEqual(voice.len, 12); XCTAssertEqual(voice.refSeconds, 2, accuracy: 1e-6)
        XCTAssertEqual(voice.state.count, 12 * speakerDim)
        XCTAssertThrowsError(try engine.enroll(clips48k: [[Float](repeating: 0.1, count: 4800)])) // 0.1 s is too short
    }

    func testSynthesisRunsTheGraphsInOrderAndStitchesTheAudio() throws {
        let runner = FakeRunner()
        let engine = IrodoriEngine(runner: runner, tokenizer: tokenizer)
        var chunks = [[Float]]()
        let stats = try engine.synth(voice: voice, text: "今日はとてもいい天気です。", seed: 7) { chunks.append($0) }
        XCTAssertEqual(runner.calls, ["text_encoder", "text_encoder", "duration", "context_kv"] + Array(repeating: "dit_step", count: 4) + ["dacvae_decode", "dacvae_decode"])
        XCTAssertEqual(stats.frames, 60); XCTAssertEqual(stats.tokens, 1 + tokenizer.encode("今日はとてもいい天気です。").count)
        XCTAssertEqual(chunks.map { $0.count }, [25 * 1920, 35 * 1920]) // first chunk 1 s, the rest follows
        XCTAssertGreaterThan(stats.firstAudioMs, 0)
        // zero velocity: the decoder sees the initial noise, so the audio is that noise stretched to samples
        var rng = JavaRandom(seed: 7)
        let noise = (0..<(60 * 32)).map { _ in Float(rng.nextGaussian()) }
        let audio = chunks.flatMap { $0 }
        for frame in [0, 1, 24, 25, 26, 40, 59] { XCTAssertEqual(audio[frame * 1920 + 5], noise[frame * 32], accuracy: 1e-6, "frame \(frame)") }
        // the graph inputs carry the documented names
        let dit = runner.inputsSeen["dit_step"]![0]
        for key in ["x_t", "t", "delta_t", "text_state", "speaker_state", "caption_state", "has_speaker", "k0", "v0"] { XCTAssertNotNil(dit[key], key) }
        XCTAssertEqual(dit["x_t"]!.shape, [1, 60, 32]); XCTAssertEqual(dit["has_caption"]!.floats, [0])
        XCTAssertEqual(runner.inputsSeen["text_encoder"]![0]["input_ids"]!.ints, [Int64(tokenizer.bosId)]) // the empty caption comes first
        XCTAssertTrue(runner.inputsSeen["text_encoder"]![1]["input_ids"]!.isInt64)
    }

    func testRFAddsTheGuidanceRuns() throws {
        let runner = FakeRunner()
        let engine = IrodoriEngine(runner: runner, tokenizer: tokenizer, flow: .rf)
        _ = try engine.synth(voice: voice, text: "こんにちは", steps: 4) { _ in }
        XCTAssertEqual(runner.calls.filter { $0 == "context_kv" }.count, 3) // full, no text, no speaker
        XCTAssertEqual(runner.calls.filter { $0 == "dit_step" }.count, 4 + 2 * 2) // 2 of 4 steps are guided
        let guided = runner.inputsSeen["dit_step"]!.filter { $0["text_mask"]!.floats.allSatisfy { $0 == 0 } }
        XCTAssertEqual(guided.count, 2)
    }

    func testMemorySavingModeReleasesEachGraphAfterUse() throws {
        let runner = FakeRunner()
        let engine = IrodoriEngine(runner: runner, tokenizer: tokenizer, lowMemory: true)
        _ = try engine.synth(voice: voice, text: "こんにちは") { _ in }
        for graph in ["text_encoder", "duration", "context_kv", "dit_step", "dacvae_decode"] { XCTAssertTrue(runner.released.contains(graph), graph) }
    }

    func testCancellationStopsBetweenChunks() {
        let runner = FakeRunner()
        let engine = IrodoriEngine(runner: runner, tokenizer: tokenizer)
        var delivered = 0
        XCTAssertThrowsError(try engine.synth(voice: voice, text: "こんにちは", cancelled: { delivered >= 1 }) { _ in delivered += 1 }) {
            XCTAssertEqual($0 as? EngineError, .cancelled)
        }
        XCTAssertEqual(delivered, 1)
    }

    func testAFlatTailIsDetectedAndCut() throws {
        // frames 30... are silence-like (all zero): the window rule finds the first fully flat window
        var z = [Float](repeating: 0, count: 60 * 32)
        var rng = JavaRandom(seed: 3)
        for i in 0..<(30 * 32) { z[i] = Float(rng.nextGaussian()) }
        XCTAssertEqual(IrodoriEngine.flatteningPoint(z, frames: 60), 30)
        XCTAssertNil(IrodoriEngine.flatteningPoint((0..<(60 * 32)).map { _ in Float(rng.nextGaussian()) }, frames: 60))
        let runner = FakeRunner()
        runner.dit = { x in // MF one step: x_new = x - v, so v = x drives the second half of the latent to zero
            var v = [Float](repeating: 0, count: x.floats.count)
            for i in (30 * 32)..<x.floats.count { v[i] = x.floats[i] } // x - v over one unit step = 0
            return v
        }
        var chunks = [[Float]]()
        _ = try IrodoriEngine(runner: runner, tokenizer: tokenizer).synth(voice: voice, text: "こんにちは", steps: 1, seed: 3) { chunks.append($0) }
        XCTAssertEqual(chunks.flatMap { $0 }.count, 30 * 1920)
    }
}
