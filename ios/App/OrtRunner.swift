import Foundation
import OnnxRuntimeBindings
import VoiceCloneCore

/// Runs the model graphs with ONNX Runtime (CPU). One session per graph, created on first use.
final class OrtRunner: GraphRunner {
    private let env: ORTEnv
    private let directory: URL
    private let threads: Int
    private var sessions = [String: ORTSession]()
    private let lock = NSLock()
    private var cancelRequested = false

    init(directory: URL, threads: Int = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)) throws {
        env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        self.directory = directory
        self.threads = threads
    }

    /// Opens a graph now (used to check that every graph of a downloaded pack can be loaded on this device).
    func open(_ name: String) throws { _ = try session(name) }

    private func session(_ name: String) throws -> ORTSession {
        lock.lock(); defer { lock.unlock() }
        if let existing = sessions[name] { return existing }
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(Int32(threads))
        try options.setGraphOptimizationLevel(ORTGraphOptimizationLevel.all)
        let created = try ORTSession(env: env, modelPath: directory.appendingPathComponent("\(name).onnx").path, sessionOptions: options)
        sessions[name] = created
        return created
    }

    func run(_ graph: String, inputs: [String: Tensor]) throws -> [NamedTensor] {
        if cancelRequested { throw EngineError.cancelled }
        let session = try self.session(graph)
        let declared = Set(try session.inputNames())
        var feeds = [String: ORTValue]()
        for (name, tensor) in inputs where declared.contains(name) { feeds[name] = try makeValue(tensor) }
        let outputNames = try session.outputNames()
        let results = try session.run(withInputs: feeds, outputNames: Set(outputNames), runOptions: nil)
        return try outputNames.map { name in
            guard let value = results[name] else { throw EngineError.message("モデルの出力 \(name) が見つかりません") }
            return NamedTensor(name: name, tensor: try makeTensor(value))
        }
    }

    func release(_ graph: String) {
        lock.lock(); sessions[graph] = nil; lock.unlock()
    }

    func cancel() { cancelRequested = true }
    func resetCancel() { cancelRequested = false }

    private func makeValue(_ tensor: Tensor) throws -> ORTValue {
        let shape = tensor.shape.map { NSNumber(value: $0) }
        if tensor.isInt64 {
            let data = NSMutableData(length: tensor.ints.count * MemoryLayout<Int64>.size)!
            tensor.ints.withUnsafeBytes { data.replaceBytes(in: NSRange(location: 0, length: $0.count), withBytes: $0.baseAddress!) }
            return try ORTValue(tensorData: data, elementType: ORTTensorElementDataType.int64, shape: shape)
        }
        let data = NSMutableData(length: tensor.floats.count * MemoryLayout<Float>.size)!
        tensor.floats.withUnsafeBytes { data.replaceBytes(in: NSRange(location: 0, length: $0.count), withBytes: $0.baseAddress!) }
        return try ORTValue(tensorData: data, elementType: ORTTensorElementDataType.float, shape: shape)
    }

    private func makeTensor(_ value: ORTValue) throws -> Tensor {
        let info = try value.tensorTypeAndShapeInfo()
        let shape = info.shape.map { $0.intValue }
        let data = try value.tensorData() as Data
        switch info.elementType {
        case ORTTensorElementDataType.float:
            return .float(data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }, shape)
        case ORTTensorElementDataType.int64:
            return .int64(data.withUnsafeBytes { Array($0.bindMemory(to: Int64.self)) }, shape)
        default:
            throw EngineError.message("対応していないモデルの出力形式です")
        }
    }
}

/// Owns the engine and runs all model work on one background queue, so the screens never wait for it.
final class EngineHost {
    private let queue = DispatchQueue(label: "com.voiceclone.engine", qos: .userInitiated)
    private var runner: OrtRunner?
    private var engine: IrodoriEngine?
    private var loadedDirectory: URL?

    /// Runs [work] on the engine queue with an engine for [directory] (loaded on first use).
    func run<T>(directory: URL, flow: FlowKind, lowMemory: Bool = false, _ work: @escaping (IrodoriEngine, OrtRunner) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if self.engine == nil || self.loadedDirectory != directory {
                        let runner = try OrtRunner(directory: directory)
                        let tokenizer = try UnigramTokenizer.load(directory.appendingPathComponent("tokenizer.json"))
                        self.runner = runner
                        self.engine = IrodoriEngine(runner: runner, tokenizer: tokenizer, flow: flow, lowMemory: lowMemory)
                        self.loadedDirectory = directory
                    }
                    self.runner?.resetCancel()
                    continuation.resume(returning: try work(self.engine!, self.runner!))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Stops the work in progress. Safe to call from any thread.
    func cancel() { runner?.cancel() }

    func unload() { queue.async { self.engine = nil; self.runner = nil; self.loadedDirectory = nil } }
}
