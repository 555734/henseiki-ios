import Foundation

/// A dense tensor handed to / returned from a model graph. float32 or int64, row-major.
public struct Tensor {
    public var shape: [Int]
    public var floats: [Float]
    public var ints: [Int64]
    public let isInt64: Bool

    public static func float(_ data: [Float], _ shape: [Int]) -> Tensor {
        precondition(data.count == shape.reduce(1, *), "tensor data does not match its shape")
        return Tensor(shape: shape, floats: data, ints: [], isInt64: false)
    }
    public static func int64(_ data: [Int64], _ shape: [Int]) -> Tensor {
        precondition(data.count == shape.reduce(1, *), "tensor data does not match its shape")
        return Tensor(shape: shape, floats: [], ints: data, isInt64: true)
    }
    public static func scalar(_ value: Float) -> Tensor { .float([value], [1]) }
    public func dim(_ i: Int) -> Int { shape[i] }
}

public struct NamedTensor {
    public let name: String
    public let tensor: Tensor
    public init(name: String, tensor: Tensor) { self.name = name; self.tensor = tensor }
}

public enum EngineError: Error, LocalizedError, Equatable {
    case cancelled
    case message(String)
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "処理を停止しました"
        case .message(let text): return text
        }
    }
}

/// Runs one of the model graphs (text_encoder, duration, context_kv, dit_step, dacvae_encode, speaker_encoder,
/// dacvae_decode). The app implements this with ONNX Runtime; the tests implement it with small fakes.
public protocol GraphRunner: AnyObject {
    /// Runs [graph] with [inputs]; inputs the graph does not declare are ignored. Outputs come back in the graph's order.
    func run(_ graph: String, inputs: [String: Tensor]) throws -> [NamedTensor]
    /// Frees a graph that is not needed any more (memory-saving mode).
    func release(_ graph: String)
    /// Stops the run in progress as soon as possible.
    func cancel()
}
