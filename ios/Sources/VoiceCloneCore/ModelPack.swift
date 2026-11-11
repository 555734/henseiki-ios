import Foundation

/// Which model a pack is for. iOS ships the recommended MF mixed8 model; RF is listed for completeness.
public enum ModelProfile: String, CaseIterable {
    case mfMixed8 = "mf-mixed8"
    case rfMixed8 = "rf-mixed8"

    public var flow: FlowKind { self == .mfMixed8 ? .mf : .rf }
    public var directory: String { self == .mfMixed8 ? "irodori-v4.1-small-mf-mixed8" : "irodori-v4.1-small-rf-mixed8" }
    public var defaultSteps: Int { self == .mfMixed8 ? 4 : 40 }
    public var tag: String { "models-\(rawValue)-v1" }
    public var packName: String { "irodori-\(rawValue).zip" }
}

/// Portable, checksummed model packs (the same ZIPs the Android app downloads). Import validates into a sibling
/// staging directory first. Packs are written with ZIP_STORED, so extraction is a straight copy.
public enum ModelPack {
    public static let files: Set<String> = ["tokenizer.json", "text_encoder.onnx", "dit_step.onnx", "duration.onnx",
        "context_kv.onnx", "speaker_encoder.onnx", "dacvae_encode.onnx", "dacvae_decode.onnx"]
    static let maxFile: Int64 = 2_000_000_000
    static let maxTotal: Int64 = 4_000_000_000

    public struct Entry: Equatable { public let name: String; public let size: Int64; public let sha256: String }
    public struct Manifest { public let profile: ModelProfile; public let files: [Entry] }
    public struct Catalog: Equatable { public let size: Int64; public let unpacked: Int64; public let sha256: String }

    public static func downloadURL(_ profile: ModelProfile, repository: String, name: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/download/\(profile.tag)/\(name)")!
    }

    public static func parseCatalog(_ data: Data, profile: ModelProfile) throws -> Catalog {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["format_version"] as? Int) == 1, (json["profile"] as? String) == profile.rawValue,
              (json["asset"] as? String) == profile.packName,
              let size = (json["size"] as? NSNumber)?.int64Value, let unpacked = (json["unpacked_size"] as? NSNumber)?.int64Value,
              let sha = json["sha256"] as? String else { throw EngineError.message("モデルの配布情報が一致しません") }
        guard (1...2_000_000_000).contains(size), (1...4_000_000_000).contains(unpacked), isHex64(sha) else {
            throw EngineError.message("モデルの配布情報が不正です")
        }
        return Catalog(size: size, unpacked: unpacked, sha256: sha)
    }

    public static func readManifest(_ data: Data, expected: ModelProfile) throws -> Manifest {
        guard (1...65536).contains(data.count) else { throw EngineError.message("モデル一覧のサイズが不正です") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["format_version"] as? Int) == 1, (json["profile"] as? String) == expected.rawValue else {
            throw EngineError.message("選択したモデルとZIPの種類が違います")
        }
        guard (json["precision"] as? String) == "mixed8", (json["flow"] as? String) == expected.flow.rawValue else {
            throw EngineError.message("選択したモデルとZIPの種類が違います")
        }
        guard (json["deterministic_encoder"] as? Bool) == true else { throw EngineError.message("決定的な参照エンコーダが必要です") }
        guard let array = json["files"] as? [[String: Any]], array.count == files.count else { throw EngineError.message("モデル一覧が不正です") }
        var entries = [Entry]()
        for item in array {
            guard let name = item["name"] as? String, let size = (item["size"] as? NSNumber)?.int64Value, let sha = item["sha256"] as? String,
                  (1...maxFile).contains(size), isHex64(sha) else { throw EngineError.message("モデル一覧が不正です") }
            entries.append(Entry(name: name, size: size, sha256: sha))
        }
        guard Set(entries.map { $0.name }) == files, entries.reduce(0, { $0 + $1.size }) <= maxTotal else { throw EngineError.message("モデル一覧が不正です") }
        return Manifest(profile: expected, files: entries)
    }

    static func isHex64(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    /// True when [directory] holds a complete, verified pack for [profile] (manifest.ok matches the manifest's hash).
    public static func isReady(_ directory: URL, profile: ModelProfile) -> Bool {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL), let manifest = try? readManifest(data, expected: profile),
              let ok = try? String(contentsOf: directory.appendingPathComponent("manifest.ok"), encoding: .utf8), ok == SHA256Hasher.hex(of: data) else { return false }
        return manifest.files.allSatisfy {
            ((try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent($0.name).path)[.size]) as? NSNumber)?.int64Value == $0.size
        }
    }

    /// Unpacks a pack ZIP into [root]/[profile.directory] after verifying every file; the previous install is kept
    /// until the new one is complete. [validate] may reject the staged files (for example unsupported operators).
    public static func install(zip: URL, root: URL, profile: ModelProfile, validate: (URL) throws -> Void = { _ in },
                               cancelled: () -> Bool = { false }, progress: (String) -> Void = { _ in }) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent(".\(profile.directory)-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        let entries = try StoredZip.extract(zip, to: stage, allowed: files.union(["manifest.json"]), limit: { $0 == "manifest.json" ? 65536 : maxFile },
                                            totalLimit: maxTotal + 65536, cancelled: cancelled, progress: { progress("\($0) を取り込み中…") })
        guard Set(entries) == files.union(["manifest.json"]) else { throw EngineError.message("モデルZIPに必要なファイルがありません") }
        let manifestData = try Data(contentsOf: stage.appendingPathComponent("manifest.json"))
        let manifest = try readManifest(manifestData, expected: profile)
        for entry in manifest.files {
            progress("\(entry.name) を検証中…")
            let file = stage.appendingPathComponent(entry.name)
            let size = ((try? fm.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value
            guard size == entry.size, try SHA256Hasher.hex(ofFile: file, shouldStop: cancelled) == entry.sha256 else {
                throw EngineError.message("\(entry.name): サイズまたはSHA-256が一致しません")
            }
        }
        progress("モデルの動作対応を確認中…")
        try validate(stage)
        try SHA256Hasher.hex(of: manifestData).write(to: stage.appendingPathComponent("manifest.ok"), atomically: true, encoding: .utf8)
        if cancelled() { throw EngineError.cancelled }
        let target = root.appendingPathComponent(profile.directory)
        let backup = root.appendingPathComponent(".\(profile.directory)-previous-\(UUID().uuidString)")
        if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: backup) }
        do { try fm.moveItem(at: stage, to: target) } catch {
            if fm.fileExists(atPath: backup.path) { try? fm.moveItem(at: backup, to: target) }
            throw EngineError.message("モデルを保存できません")
        }
        try? fm.removeItem(at: backup)
    }
}

/// Minimal ZIP reader for archives whose entries are stored uncompressed (the model packs). Entries are copied to
/// disk in 1 MB pieces, so a 1 GB pack never has to fit in memory. Sizes come from the central directory (ZIP64 aware).
public enum StoredZip {
    private static func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | (Int(b[o + 1]) << 8) }
    private static func u32(_ b: [UInt8], _ o: Int) -> Int64 { Int64(b[o]) | (Int64(b[o + 1]) << 8) | (Int64(b[o + 2]) << 16) | (Int64(b[o + 3]) << 24) }
    private static func u64(_ b: [UInt8], _ o: Int) -> Int64 { u32(b, o) | (u32(b, o + 4) << 32) }

    struct Item { let name: String; let size: Int64; let method: Int; let headerOffset: Int64 }

    static func entries(of handle: FileHandle, fileSize: Int64) throws -> [Item] {
        let tailLength = Int(min(fileSize, 65_536 + 22 + 20))
        handle.seek(toFileOffset: UInt64(fileSize) - UInt64(tailLength))
        let tail = [UInt8](handle.readData(ofLength: tailLength))
        guard let eocd = (0...(tail.count - 22)).reversed().first(where: { u32(tail, $0) == 0x06054b50 }) else { throw EngineError.message("モデルZIPが壊れています") }
        var count = Int64(u16(tail, eocd + 10)), directorySize = u32(tail, eocd + 12), directoryOffset = u32(tail, eocd + 16)
        if (count == 0xFFFF || directorySize == 0xFFFFFFFF || directoryOffset == 0xFFFFFFFF), eocd >= 20, u32(tail, eocd - 20) == 0x07064b50 {
            let locator = eocd - 20
            let zip64Offset = u64(tail, locator + 8)
            handle.seek(toFileOffset: UInt64(zip64Offset))
            let record = [UInt8](handle.readData(ofLength: 56))
            guard record.count == 56, u32(record, 0) == 0x06064b50 else { throw EngineError.message("モデルZIPが壊れています") }
            count = u64(record, 32); directorySize = u64(record, 40); directoryOffset = u64(record, 48)
        }
        guard directorySize > 0, directorySize < 16_000_000 else { throw EngineError.message("モデルZIPが壊れています") }
        handle.seek(toFileOffset: UInt64(directoryOffset))
        let directory = [UInt8](handle.readData(ofLength: Int(directorySize)))
        var items = [Item]()
        var p = 0
        while p + 46 <= directory.count && Int64(items.count) < count {
            guard u32(directory, p) == 0x02014b50 else { throw EngineError.message("モデルZIPが壊れています") }
            let method = u16(directory, p + 10)
            var size = u32(directory, p + 24)
            var offset = u32(directory, p + 42)
            let nameLength = u16(directory, p + 28), extraLength = u16(directory, p + 30), commentLength = u16(directory, p + 32)
            let name = String(decoding: directory[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            if size == 0xFFFFFFFF || offset == 0xFFFFFFFF { // ZIP64 extra field
                var e = p + 46 + nameLength
                let extraEnd = e + extraLength
                while e + 4 <= extraEnd {
                    let id = u16(directory, e), length = u16(directory, e + 2)
                    if id == 1 {
                        var q = e + 4 // ZIP64 fields appear in this order, only for values stored as 0xFFFFFFFF
                        if u32(directory, p + 24) == 0xFFFFFFFF { size = u64(directory, q); q += 8 }   // uncompressed size
                        if u32(directory, p + 20) == 0xFFFFFFFF { q += 8 }                             // compressed size (unused)
                        if u32(directory, p + 42) == 0xFFFFFFFF { offset = u64(directory, q) }         // local header offset
                    }
                    e += 4 + length
                }
            }
            items.append(Item(name: name, size: size, method: method, headerOffset: offset))
            p += 46 + nameLength + extraLength + commentLength
        }
        return items
    }

    /// Extracts the archive's entries into [directory]; returns the entry names. Only names in [allowed] are accepted.
    public static func extract(_ zip: URL, to directory: URL, allowed: Set<String>, limit: (String) -> Int64, totalLimit: Int64,
                               cancelled: () -> Bool, progress: (String) -> Void) throws -> [String] {
        let size = ((try FileManager.default.attributesOfItem(atPath: zip.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard size >= 22 else { throw EngineError.message("モデルZIPが壊れています") }
        let handle = try FileHandle(forReadingFrom: zip)
        defer { try? handle.close() }
        var names = [String]()
        var total: Int64 = 0
        for item in try entries(of: handle, fileSize: size) {
            if cancelled() { throw EngineError.cancelled }
            guard !item.name.hasSuffix("/"), allowed.contains(item.name) else { throw EngineError.message("モデルZIPに不正なファイルがあります: \(item.name)") }
            guard !names.contains(item.name) else { throw EngineError.message("ZIPに同名のファイルがあります") }
            guard item.method == 0 else { throw EngineError.message("モデルZIPは無圧縮（STORED）形式である必要があります") }
            guard item.size <= limit(item.name) else { throw EngineError.message("モデルZIPが大きすぎます") }
            handle.seek(toFileOffset: UInt64(item.headerOffset))
            let header = [UInt8](handle.readData(ofLength: 30))
            guard header.count == 30, u32(header, 0) == 0x04034b50 else { throw EngineError.message("モデルZIPが壊れています") }
            handle.seek(toFileOffset: UInt64(item.headerOffset) + 30 + UInt64(u16(header, 26)) + UInt64(u16(header, 28)))
            progress(item.name)
            let destination = directory.appendingPathComponent(item.name)
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let out = try FileHandle(forWritingTo: destination)
            defer { try? out.close() }
            var remaining = item.size
            while remaining > 0 {
                if cancelled() { throw EngineError.cancelled }
                let chunk = handle.readData(ofLength: Int(min(remaining, 1 << 20)))
                if chunk.isEmpty { throw EngineError.message("モデルZIPが途中で終わっています") }
                out.write(chunk)
                remaining -= Int64(chunk.count)
                total += Int64(chunk.count)
                guard total <= totalLimit else { throw EngineError.message("モデルZIPが大きすぎます") }
            }
            names.append(item.name)
        }
        return names
    }
}
