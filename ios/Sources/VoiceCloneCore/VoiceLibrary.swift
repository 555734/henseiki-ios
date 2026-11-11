import Foundation

/// Every voice the user has registered, so a registered voice can be switched back to with one tap.
/// [activeFile] (voice.bin) is always the voice used for reading; each voice is also kept as `<id>.bin` in [directory]
/// with a small index. Voices are identified by the SHA-256 of their data, so installing the same voice again
/// selects the existing entry instead of adding a copy. (Port of the Android `VoiceLibrary`.)
public final class VoiceLibrary {
    public struct Entry: Codable, Equatable {
        public var id: String
        public var name: String
        public var source: String
        public var createdAt: Double       // seconds since 1970
        public var refSeconds: Float
        public var sha256: String
    }

    private struct Index: Codable {
        var active: String
        var fingerprint: String
        var voices: [Entry]
    }

    public static let maxNameLength = 20
    private let directory: URL
    private let activeFile: URL
    private let lock = NSLock()
    private var indexFile: URL { directory.appendingPathComponent("index.json") }

    public init(directory: URL, activeFile: URL) {
        self.directory = directory
        self.activeFile = activeFile
    }

    public func list() -> [Entry] { locked { adoptUnknownActive(load()).voices } }
    public func activeId() -> String? { locked { let a = adoptUnknownActive(load()).active; return a.isEmpty ? nil : a } }

    /// Makes the library match the current active file: selects its entry, or adds it as a new voice.
    @discardableResult
    public func sync(source: String, now: Date = Date()) -> Entry? {
        locked {
            var index = load()
            guard let bytes = try? Data(contentsOf: activeFile) else { index.active = ""; save(&index); return nil }
            let hash = SHA256Hasher.hex(of: bytes)
            let entry = index.voices.first { $0.sha256 == hash } ?? add(&index, bytes: bytes, hash: hash, source: source, now: now)
            index.active = entry.id
            save(&index)
            return entry
        }
    }

    /// Switches reading to voice [id]. Returns the entry, or nil when it does not exist (nothing changes).
    @discardableResult
    public func activate(_ id: String) -> Entry? {
        locked {
            var index = load()
            guard let entry = index.voices.first(where: { $0.id == id }),
                  let bytes = try? Data(contentsOf: directory.appendingPathComponent("\(id).bin")) else { return nil }
            guard (try? bytes.write(to: activeFile, options: .atomic)) != nil else { return nil }
            index.active = id
            save(&index)
            return entry
        }
    }

    @discardableResult
    public func rename(_ id: String, to name: String) -> Bool {
        locked {
            let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(VoiceLibrary.maxNameLength))
            if clean.isEmpty { return false }
            var index = load()
            guard let i = index.voices.firstIndex(where: { $0.id == id }) else { return false }
            index.voices[i].name = clean
            save(&index)
            return true
        }
    }

    /// Removes voice [id]. When it was the active one, the newest remaining voice becomes active (or none is left).
    /// Returns the voice that is active afterwards.
    @discardableResult
    public func delete(_ id: String) -> Entry? {
        locked {
            var index = load()
            guard let i = index.voices.firstIndex(where: { $0.id == id }) else { return nil }
            index.voices.remove(at: i)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).bin"))
            if index.active == id {
                if let next = index.voices.max(by: { $0.createdAt < $1.createdAt }),
                   let bytes = try? Data(contentsOf: directory.appendingPathComponent("\(next.id).bin")) {
                    try? bytes.write(to: activeFile, options: .atomic)
                    index.active = next.id
                } else {
                    try? FileManager.default.removeItem(at: activeFile)
                    index.active = ""
                }
            }
            save(&index)
            return index.voices.first { $0.id == index.active }
        }
    }

    /// Deletes every registered voice and the active voice file.
    public func clear() {
        locked {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: activeFile)
        }
    }

    // MARK: - private

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    private func fingerprint() -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: activeFile.path) else { return "" }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size):\(modified)"
    }

    /// A voice file that exists without an entry (installed before the library existed) becomes an entry.
    private func adoptUnknownActive(_ loaded: Index) -> Index {
        var index = loaded
        guard FileManager.default.fileExists(atPath: activeFile.path) else { return index }
        if index.fingerprint == fingerprint() { return index }
        guard let bytes = try? Data(contentsOf: activeFile) else { return index }
        let hash = SHA256Hasher.hex(of: bytes)
        if let known = index.voices.first(where: { $0.sha256 == hash }) {
            if index.active != known.id { index.active = known.id; save(&index) }
            return index
        }
        let entry = add(&index, bytes: bytes, hash: hash, source: "registered", now: Date())
        index.active = entry.id
        save(&index)
        return index
    }

    private func add(_ index: inout Index, bytes: Data, hash: String, source: String, now: Date) -> Entry {
        let prefix = source == "imported" ? "取り込んだ声" : "声"
        let used = index.voices.compactMap { voice -> Int? in
            guard voice.name.hasPrefix(prefix + " ") else { return nil }
            return Int(voice.name.dropFirst(prefix.count + 1))
        }
        let number = (used.max() ?? 0) + 1
        let id = "v" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        let entry = Entry(id: id, name: "\(prefix) \(number)", source: source, createdAt: now.timeIntervalSince1970,
                          refSeconds: Voice.referenceSeconds(of: bytes), sha256: hash)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? bytes.write(to: directory.appendingPathComponent("\(id).bin"), options: .atomic)
        index.voices.append(entry)
        return entry
    }

    private func load() -> Index {
        guard let data = try? Data(contentsOf: indexFile), var index = try? JSONDecoder().decode(Index.self, from: data) else {
            return Index(active: "", fingerprint: "", voices: [])
        }
        index.voices = index.voices.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent("\($0.id).bin").path) }
        return index
    }

    private func save(_ index: inout Index) {
        index.fingerprint = fingerprint()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: indexFile, options: .atomic) }
    }
}
