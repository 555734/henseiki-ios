import Foundation

/// Audio helpers (no platform dependencies). Same maths as the Android `AudioDsp`.
public enum AudioDsp {
    public static let sampleRate = 48000

    // BS.1770 K-weighting at 48 kHz, identical to pyloudnorm.Meter(48000)
    private static let shelfB = [1.5351828863637502, -2.691804030199196, 1.198426263333146]
    private static let shelfA = [1.0, -1.6906995865986896, 0.7325047060963897]
    private static let highpassB = [0.9950442970178917, -1.9900885940357833, 0.9950442970178917]
    private static let highpassA = [1.0, -1.990076284018423, 0.9901009040531438]

    private static func biquad(_ x: [Double], _ b: [Double], _ a: [Double]) -> [Double] {
        var y = [Double](repeating: 0, count: x.count)
        var z1 = 0.0, z2 = 0.0
        for i in 0..<x.count { // direct form II transposed, like scipy.signal.lfilter
            let out = b[0] * x[i] + z1
            z1 = b[1] * x[i] - a[1] * out + z2
            z2 = b[2] * x[i] - a[2] * out
            y[i] = out
        }
        return y
    }

    /// Integrated loudness (LUFS) of a mono 48 kHz signal, gated as in pyloudnorm.
    public static func integratedLoudness(_ wav: [Float]) -> Double {
        let k = biquad(biquad(wav.map { Double($0) }, shelfB, shelfA), highpassB, highpassA)
        let tg = 0.4, step = 0.25
        let nBlocks = Int(((Double(k.count) / Double(sampleRate) - tg) / (tg * step)).rounded(.toNearestOrAwayFromZero)) + 1
        if nBlocks <= 0 { return -Double.infinity }
        var z = [Double]()
        z.reserveCapacity(nBlocks)
        for j in 0..<nBlocks {
            let l = Int(tg * (Double(j) * step) * Double(sampleRate))
            let u = min(k.count, Int(tg * (Double(j) * step + 1) * Double(sampleRate)))
            var s = 0.0
            if l < u { for i in l..<u { s += k[i] * k[i] } }
            z.append(s / (tg * Double(sampleRate)))
        }
        func lufs(_ v: Double) -> Double { -0.691 + 10 * log10(v) }
        let absGated = z.filter { lufs($0) >= -70.0 }
        if absGated.isEmpty { return -Double.infinity }
        let rel = lufs(absGated.reduce(0, +) / Double(absGated.count)) - 10.0
        let gated = z.filter { lufs($0) > rel && lufs($0) > -70.0 }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    /// Upstream reference preprocessing: loudness-normalise to [targetDb] LUFS, then peak-limit to 1.
    public static func normalizeLoudness(_ wav: [Float], targetDb: Double = -16.0) -> [Float] {
        let l = integratedLoudness(wav)
        if !l.isFinite { return wav }
        let gain = Float(pow(10.0, (targetDb - l) / 20.0))
        var out = wav.map { $0 * gain }
        let peak = out.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 1 { for i in 0..<out.count { out[i] /= peak } }
        return out
    }

    /// Pad to a multiple of [hop] with reflection (numpy `mode="reflect"`).
    public static func reflectPad(_ wav: [Float], hop: Int) -> [Float] {
        let rem = wav.count % hop
        if rem == 0 { return wav }
        let pad = hop - rem
        var out = wav
        out.reserveCapacity(wav.count + pad)
        for i in 0..<pad { out.append(wav[max(0, wav.count - 2 - i)]) }
        return out
    }

    /// Remove leading/trailing silence (frames 40 dB below the loudest), keeping 0.15 s margins.
    public static func trimSilence(_ wav: [Float], sampleRate sr: Int = AudioDsp.sampleRate) -> [Float] {
        let frame = sr / 50
        let n = wav.count / frame
        if n < 3 { return wav }
        var rms = [Double](repeating: 0, count: n)
        for f in 0..<n {
            var s = 0.0
            for i in (f * frame)..<((f + 1) * frame) { s += Double(wav[i]) * Double(wav[i]) }
            rms[f] = (s / Double(frame)).squareRoot()
        }
        let th = (rms.max() ?? 0) * 0.01
        guard let first = rms.firstIndex(where: { $0 > th }), let last = rms.lastIndex(where: { $0 > th }) else { return wav }
        let margin = Int(0.15 * Double(sr))
        let a = max(0, first * frame - margin)
        let b = min(wav.count, (last + 1) * frame + margin)
        return Array(wav[a..<b])
    }

    /// Linear-interpolation resampler (for microphones or files that are not 48 kHz).
    public static func resample(_ wav: [Float], from: Int, to: Int = AudioDsp.sampleRate) -> [Float] {
        if from == to || wav.isEmpty { return wav }
        let n = Int(Int64(wav.count) * Int64(to) / Int64(from))
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let pos = Double(i) * Double(from) / Double(to)
            let j = Int(pos)
            let f = Float(pos - Double(j))
            let a = wav[min(j, wav.count - 1)]
            let b = wav[min(j + 1, wav.count - 1)]
            out[i] = a + (b - a) * f
        }
        return out
    }

    /// 16-bit mono PCM WAV file bytes.
    public static func wavData(_ wav: [Float], sampleRate sr: Int = AudioDsp.sampleRate) -> Data {
        var data = Data()
        func le32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func le16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); le32(36 + wav.count * 2); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1); le32(sr); le32(sr * 2); le16(2); le16(16)
        data.append(contentsOf: Array("data".utf8)); le32(wav.count * 2)
        for v in wav { le16(Int(max(-1, min(1, v)) * 32767)) }
        return data
    }
}
