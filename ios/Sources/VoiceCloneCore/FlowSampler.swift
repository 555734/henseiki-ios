import Foundation

public enum FlowKind: String { case mf, rf }
public enum FlowCondition: CaseIterable { case full, noText, noSpeaker }

/// Euler sampler for the flow-matching DiT. RF defaults match upstream sample_euler_rf_cfg (independent text/speaker
/// CFG, mask mode). MF has CFG distilled into its weights and must not receive runtime CFG.
public enum FlowSampler {
    public static func sample(initial: [Float], steps: Int, flow: FlowKind,
                              cancelled: () -> Bool = { false },
                              predict: (_ x: [Float], _ t: Float, _ delta: Float, _ condition: FlowCondition) throws -> [Float]) throws -> [Float] {
        precondition(steps > 0)
        var x = initial
        let start: Float = flow == .rf ? 0.999 : 1
        for i in 0..<steps {
            if cancelled() { throw EngineError.cancelled }
            let t = start * (1 - Float(i) / Float(steps))
            let nt = start * (1 - Float(i + 1) / Float(steps))
            let delta: Float = flow == .mf ? t - nt : 0
            var v = try predict(x, t, delta, .full)
            precondition(v.count == x.count)
            if flow == .rf && t >= 0.5 {
                let noText = try predict(x, t, delta, .noText)
                let noSpeaker = try predict(x, t, delta, .noSpeaker)
                precondition(noText.count == v.count && noSpeaker.count == v.count)
                for j in 0..<v.count { v[j] = v[j] + 3 * (v[j] - noText[j]) + 5 * (v[j] - noSpeaker[j]) }
            }
            for j in 0..<x.count { x[j] = x[j] + v[j] * (nt - t) }
        }
        return x
    }
}

/// java.util.Random, so the same seed gives the same noise (and the same voice) as the Android app.
public struct JavaRandom {
    private var seed: Int64
    private var nextNextGaussian = 0.0
    private var haveNextNextGaussian = false

    public init(seed: Int64) { self.seed = (seed ^ 0x5DEECE66D) & ((1 << 48) - 1) }

    private mutating func next(_ bits: Int) -> Int32 {
        seed = (seed &* 0x5DEECE66D &+ 0xB) & ((1 << 48) - 1)
        return Int32(truncatingIfNeeded: seed >> Int64(48 - bits))
    }

    public mutating func nextDouble() -> Double {
        let high = Int64(next(26)) << 27
        let low = Int64(next(27))
        return Double(high + low) * (1.0 / Double(Int64(1) << 53))
    }

    public mutating func nextGaussian() -> Double {
        if haveNextNextGaussian { haveNextNextGaussian = false; return nextNextGaussian }
        var v1 = 0.0, v2 = 0.0, s = 0.0
        repeat {
            v1 = 2 * nextDouble() - 1
            v2 = 2 * nextDouble() - 1
            s = v1 * v1 + v2 * v2
        } while s >= 1 || s == 0
        let multiplier = (-2 * log(s) / s).squareRoot()
        nextNextGaussian = v2 * multiplier
        haveNextNextGaussian = true
        return v1 * multiplier
    }
}
