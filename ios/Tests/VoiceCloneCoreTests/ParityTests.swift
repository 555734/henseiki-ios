import XCTest
@testable import VoiceCloneCore

/// Compares the Swift code with outputs of the real Android (Kotlin) code on the same inputs
/// (regenerate with ios/scripts/kotlin_golden). A mismatch means the two apps would behave differently.
final class ParityTests: XCTestCase {
    func testTokenizerMatchesAndroid() throws {
        let golden = try Fixture.json("tokenizer_golden.json") as! [String: Any]
        let tokenizer = try UnigramTokenizer.load(Fixture.url("tokenizer_synthetic.json"), rareSplit: true)
        let plain = try UnigramTokenizer.load(Fixture.url("tokenizer_synthetic.json"), rareSplit: false)
        XCTAssertEqual(tokenizer.bosId, golden["bos"] as? Int)
        let cases = golden["cases"] as! [[String: Any]]
        XCTAssertGreaterThan(cases.count, 25)
        for c in cases {
            let text = c["text"] as! String
            XCTAssertEqual(tokenizer.encode(text), c["ids"] as! [Int], "ids for \(text.debugDescription)")
            XCTAssertEqual(plain.encode(text), c["idsNoRareSplit"] as! [Int], "ids (no rare split) for \(text.debugDescription)")
        }
    }

    func testTextPreparationMatchesAndroid() throws {
        for c in try Fixture.json("text_prep_golden.json") as! [[String: Any]] {
            let text = c["text"] as! String
            XCTAssertEqual(TextPrep.normalize(text), c["normalized"] as! String, "normalize \(text.debugDescription)")
            XCTAssertEqual(TextPrep.splitSentences(text), c["sentences"] as! [String], "split \(text.debugDescription)")
        }
    }

    func testAudioMathMatchesAndroid() throws {
        let g = try Fixture.json("dsp_golden.json") as! [String: Any]
        func floats(_ key: String) -> [Double] { (g[key] as! [Any]).map { ($0 as! NSNumber).doubleValue } }
        func number(_ key: String) -> Double { (g[key] as! NSNumber).doubleValue }

        let n = 48000 * 3
        let speech = (0..<n).map { i -> Float in
            let env = 0.5 + 0.5 * sin(2 * Double.pi * 2.0 * Double(i) / 48000)
            return Float(0.3 * env * sin(2 * Double.pi * 220.0 * Double(i) / 48000) + 0.1 * sin(2 * Double.pi * 1000.0 * Double(i) / 48000))
        }
        assertClose(AudioDsp.integratedLoudness(speech), number("loudness"), tolerance: 1e-6, "loudness")

        let normalized = AudioDsp.normalizeLoudness(speech, targetDb: -16)
        XCTAssertEqual(normalized.count, Int(number("normalizedLength")))
        for (a, b) in zip(normalized.prefix(6), floats("normalizedHead")) { assertClose(Double(a), b, tolerance: 1e-4) }
        for (a, b) in zip(normalized.suffix(6), floats("normalizedTail")) { assertClose(Double(a), b, tolerance: 1e-4) }
        assertClose(normalized.reduce(0) { $0 + Double($1) }, number("normalizedSum"), tolerance: 1e-3)

        let loud = AudioDsp.normalizeLoudness(speech.map { $0 * 9 }, targetDb: -10) // exercises the peak limiter
        XCTAssertEqual(loud.count, Int(number("loudLength")))
        for (a, b) in zip(loud.prefix(6), floats("loudHead")) { assertClose(Double(a), b, tolerance: 1e-4) }
        XCTAssertLessThanOrEqual(loud.map { abs($0) }.max()!, 1.0 + 1e-6)

        let odd = (0..<5003).map { Float(sin(Double($0) * 0.01)) }
        let reflected = AudioDsp.reflectPad(odd, hop: 1920)
        XCTAssertEqual(reflected.count, Int(number("reflectLength")))
        for (a, b) in zip(reflected.suffix(8), floats("reflectTail")) { assertClose(Double(a), b, tolerance: 1e-6) }

        var gapped = [Float](repeating: 0, count: 48000 * 2)
        for i in 24000..<44000 { gapped[i] = Float(0.2 * sin(2 * Double.pi * 300.0 * Double(i) / 48000)) }
        let trimmed = AudioDsp.trimSilence(gapped)
        XCTAssertEqual(trimmed.count, Int(number("trimLength")))
        for (a, b) in zip(trimmed.prefix(4), floats("trimHead")) { assertClose(Double(a), b, tolerance: 1e-5) }

        let tone = (0..<48000).map { Float(0.4 * sin(2 * Double.pi * 440.0 * Double($0) / 48000)) }
        let resampled = AudioDsp.resample(tone, from: 44100, to: 48000)
        XCTAssertEqual(resampled.count, Int(number("resampleLength")))
        for (a, b) in zip(resampled.prefix(6), floats("resampleHead")) { assertClose(Double(a), b, tolerance: 1e-4) }
        for (a, b) in zip(resampled.suffix(4), floats("resampleTail")) { assertClose(Double(a), b, tolerance: 1e-4) }
    }

    func testJavaRandomMatchesTheJDK() throws {
        let g = try Fixture.json("dsp_golden.json") as! [String: Any]
        var r = JavaRandom(seed: 42)
        for expected in (g["gaussian42"] as! [Any]).map({ ($0 as! NSNumber).doubleValue }) { assertClose(r.nextGaussian(), expected, tolerance: 1e-12) }
        var r0 = JavaRandom(seed: 0)
        for expected in (g["gaussian0"] as! [Any]).map({ ($0 as! NSNumber).doubleValue }) { assertClose(r0.nextGaussian(), expected, tolerance: 1e-12) }
    }
}
