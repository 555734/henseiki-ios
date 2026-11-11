import Foundation

/// Writes a 16-bit mono PCM WAV file incrementally, so a long reading never has to fit in memory.
/// The header is completed by [close]; until then the file is not a valid WAV.
public final class WavFileWriter {
    public let url: URL
    public let sampleRate: Int
    private let handle: FileHandle
    public private(set) var samples = 0
    private var closed = false

    public init(url: URL, sampleRate: Int = AudioDsp.sampleRate) throws {
        self.url = url
        self.sampleRate = sampleRate
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(count: 44)) else { throw EngineError.message("音声ファイルを作成できません") }
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
    }

    public func append(_ audio: [Float]) throws {
        var data = Data(capacity: audio.count * 2)
        for v in audio {
            let s = Int16(max(-1, min(1, v)) * 32767)
            var le = s.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        handle.write(data)
        samples += audio.count
    }

    /// Fills in the header and closes the file. Safe to call twice.
    public func close() throws {
        if closed { return }
        closed = true
        let header = AudioDsp.wavData([], sampleRate: sampleRate)
        var fixed = header
        func put32(_ value: Int, at offset: Int) {
            var le = UInt32(truncatingIfNeeded: value).littleEndian
            withUnsafeBytes(of: &le) { fixed.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        put32(36 + samples * 2, at: 4)
        put32(samples * 2, at: 40)
        handle.seek(toFileOffset: 0)
        handle.write(fixed)
        try handle.close()
    }

    public var seconds: Double { Double(samples) / Double(sampleRate) }
}

/// Reference recordings (mono, 48 kHz, raw Float32) kept until a voice is registered from them.
public final class ClipStore {
    private let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func list() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "f32" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @discardableResult
    public func add(_ audio: [Float]) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let next = (list().compactMap { Int($0.deletingPathExtension().lastPathComponent.dropFirst(5)) }.max() ?? -1) + 1
        let url = directory.appendingPathComponent(String(format: "clip_%03d.f32", next))
        let data = audio.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: url, options: .atomic)
        return url
    }

    public func seconds() -> Double {
        list().reduce(0) { sum, url in
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.doubleValue ?? 0
            return sum + size / 4 / Double(AudioDsp.sampleRate)
        }
    }

    public func load() throws -> [[Float]] {
        try list().map { url in
            let data = try Data(contentsOf: url)
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
    }

    public func removeLast() { if let last = list().last { try? FileManager.default.removeItem(at: last) } }
    public func clear() { try? FileManager.default.removeItem(at: directory) }
}
