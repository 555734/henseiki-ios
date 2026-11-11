import Foundation

public let speakerDim = 768

/// An enrolled voice: the speaker-encoder output, computed once and stored on the device. The file format is the
/// same as the Android app's voice.bin (big-endian: version 1, length, reference seconds, state, mask).
public struct Voice: Equatable {
    public var state: [Float]
    public var len: Int
    public var mask: [Float]
    public var refSeconds: Float

    public init(state: [Float], len: Int, mask: [Float], refSeconds: Float) {
        self.state = state; self.len = len; self.mask = mask; self.refSeconds = refSeconds
    }

    public func encoded() -> Data {
        var data = Data()
        func be32(_ v: UInt32) { var x = v.bigEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        be32(1); be32(UInt32(len)); be32(refSeconds.bitPattern)
        for v in state { be32(v.bitPattern) }
        for v in mask { be32(v.bitPattern) }
        return data
    }

    public static func decode(_ data: Data) throws -> Voice {
        let bytes = [UInt8](data)
        func be32(_ offset: Int) -> UInt32 {
            (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16) | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
        }
        guard bytes.count >= 12, be32(0) == 1 else { throw EngineError.message("声のデータが不正です") }
        let len = Int(be32(4))
        let seconds = Float(bitPattern: be32(8))
        guard len >= 1 && len <= 4096 && seconds.isFinite && seconds >= 0 else { throw EngineError.message("声のデータのヘッダーが不正です") }
        guard bytes.count == 12 + len * (speakerDim + 1) * 4 else { throw EngineError.message("声のデータのサイズが不正です") }
        var state = [Float](repeating: 0, count: len * speakerDim)
        var offset = 12
        for i in 0..<state.count { state[i] = Float(bitPattern: be32(offset)); offset += 4 }
        var mask = [Float](repeating: 0, count: len)
        for i in 0..<len { mask[i] = Float(bitPattern: be32(offset)); offset += 4 }
        return Voice(state: state, len: len, mask: mask, refSeconds: seconds)
    }

    public func save(to url: URL) throws { try encoded().write(to: url, options: .atomic) }
    public static func load(from url: URL) throws -> Voice { try decode(Data(contentsOf: url)) }

    /// The reference length stored in a voice file header; 0 when unreadable.
    public static func referenceSeconds(of data: Data) -> Float {
        guard data.count >= 12 else { return 0 }
        let b = [UInt8](data.prefix(12))
        let bits = (UInt32(b[8]) << 24) | (UInt32(b[9]) << 16) | (UInt32(b[10]) << 8) | UInt32(b[11])
        let value = Float(bitPattern: bits)
        return value.isFinite && value >= 0 ? value : 0
    }
}
