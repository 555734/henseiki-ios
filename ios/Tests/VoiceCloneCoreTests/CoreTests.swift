import XCTest
@testable import VoiceCloneCore

final class SHA256Tests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(SHA256Hasher.hex(of: Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Hasher.hex(of: Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Hasher.hex(of: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }
    func testLargeInputInPiecesEqualsOneShot() throws {
        let data = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        var h = SHA256Hasher()
        var offset = 0
        for size in [1, 63, 64, 65, 1000, 4096, 100_000] { let end = min(data.count, offset + size); h.update(data.subdata(in: offset..<end)); offset = end }
        h.update(data.subdata(in: offset..<data.count))
        XCTAssertEqual(h.finalize(), SHA256Hasher.hex(of: data))
        let file = makeTemporaryDirectory().appendingPathComponent("f.bin")
        try data.write(to: file)
        XCTAssertEqual(try SHA256Hasher.hex(ofFile: file), SHA256Hasher.hex(of: data))
    }
}

final class FlowSamplerTests: XCTestCase {
    func testMFTakesStraightEulerStepsToZeroTime() throws {
        // constant velocity v: x_end = x0 + v * (end - start) = x0 - v (t goes 1 -> 0)
        let x = try FlowSampler.sample(initial: [1, 2, 3], steps: 4, flow: .mf) { x, t, delta, kind in
            XCTAssertEqual(kind, .full)
            XCTAssertEqual(delta, 0.25, accuracy: 1e-6)
            return [Float](repeating: 2, count: x.count)
        }
        XCTAssertEqual(x, [-1, 0, 1])
    }

    func testRFUsesGuidanceOnlyWhileTimeIsAtLeastHalf() throws {
        var calls = [FlowCondition: Int]()
        _ = try FlowSampler.sample(initial: [0], steps: 4, flow: .rf) { x, t, delta, kind in
            calls[kind, default: 0] += 1
            XCTAssertEqual(delta, 0)
            switch kind { case .full: return [10]; case .noText: return [4]; case .noSpeaker: return [8] }
        }
        // t = 0.999, 0.74925, 0.4995, 0.24975 -> guidance for the first two steps only
        XCTAssertEqual(calls[.full], 4); XCTAssertEqual(calls[.noText], 2); XCTAssertEqual(calls[.noSpeaker], 2)
        // guided velocity = v + 3 (v - noText) + 5 (v - noSpeaker) = 10 + 18 + 10 = 38
        let x = try FlowSampler.sample(initial: [0], steps: 1, flow: .rf) { _, _, _, kind in
            switch kind { case .full: return [10]; case .noText: return [4]; case .noSpeaker: return [8] }
        }
        XCTAssertEqual(x[0], 38 * (0 - 0.999), accuracy: 1e-4)
    }

    func testCancellationStopsTheLoop() {
        var steps = 0
        XCTAssertThrowsError(try FlowSampler.sample(initial: [0], steps: 10, flow: .mf, cancelled: { steps >= 3 }) { x, _, _, _ in steps += 1; return x }) {
            XCTAssertEqual($0 as? EngineError, .cancelled)
        }
        XCTAssertEqual(steps, 3)
    }
}

final class VoiceTests: XCTestCase {
    func testRoundTripAndHeaderChecks() throws {
        let voice = Voice(state: (0..<(3 * speakerDim)).map { Float($0) * 0.001 }, len: 3, mask: [1, 1, 0], refSeconds: 12.5)
        let decoded = try Voice.decode(voice.encoded())
        XCTAssertEqual(decoded, voice)
        XCTAssertEqual(Voice.referenceSeconds(of: voice.encoded()), 12.5)
        XCTAssertThrowsError(try Voice.decode(Data(voice.encoded().dropLast(4))))
        XCTAssertThrowsError(try Voice.decode(Data([0, 0, 0, 2]) + voice.encoded().dropFirst(4)))
        XCTAssertEqual(Voice.referenceSeconds(of: Data([1, 2, 3])), 0)
    }

    func testBigEndianLayoutMatchesAndroid() {
        let data = Voice(state: [Float](repeating: 1, count: speakerDim), len: 1, mask: [1], refSeconds: 2).encoded()
        XCTAssertEqual([UInt8](data.prefix(12)), [0, 0, 0, 1, 0, 0, 0, 1, 0x40, 0, 0, 0])
        XCTAssertEqual(data.count, 12 + (speakerDim + 1) * 4)
    }
}

final class TextHelperTests: XCTestCase {
    func testSavedAudioName() {
        let moment = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(identifier: "Asia/Tokyo"), year: 2026, month: 11, day: 10, hour: 14, minute: 35))!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(SavedAudioName.make(text: "船の中からでは分からなかったが、島に足を踏み入れた。", now: moment, timeZone: tokyo), "VoiceClone_20261110_1435_船の中からでは分からなかったが島.wav")
        XCTAssertEqual(SavedAudioName.make(text: "a/b:\n*?\"<>|。、 ", now: moment, timeZone: tokyo), "VoiceClone_20261110_1435_ab.wav")
        XCTAssertEqual(SavedAudioName.make(text: "  \n。", now: moment, timeZone: tokyo), "VoiceClone_20261110_1435.wav")
    }

    func testWavHeader() {
        let wav = AudioDsp.wavData([0, 0.5, -1, 2], sampleRate: 48000)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(wav.count, 44 + 8)
        XCTAssertEqual([UInt8](wav[40..<44]), [8, 0, 0, 0])
        XCTAssertEqual([UInt8](wav[46..<48]), [0xFF, 0x3F]) // 0.5 -> 16383
        XCTAssertEqual([UInt8](wav[50..<52]), [0xFF, 0x7F]) // clipped to 1 -> 32767
    }

    func testPromptsAndLegalTexts() {
        XCTAssertEqual(RecordingPrompts.lines.count, 15)
        XCTAssertEqual(RecordingPrompts.registration, 6)
        XCTAssertTrue(LegalTexts.terms.contains("禁止事項")); XCTAssertTrue(LegalTexts.privacy.contains("送信しません"))
        XCTAssertTrue(LegalTexts.summary.contains("同意して始める"))
    }
}
