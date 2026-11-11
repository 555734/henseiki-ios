import Foundation
import VoiceCloneCore

/// Where the app keeps its files (all inside the app's own storage; nothing is shared unless the user exports it).
struct AppPaths {
    let root: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("VoiceClone", isDirectory: true)
        for directory in [root, models, downloads, cache] { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        // Models are large and can be downloaded again, so they are kept out of device backups.
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var mutableModels = models; try? mutableModels.setResourceValues(excluded)
        var mutableDownloads = downloads; try? mutableDownloads.setResourceValues(excluded)
    }

    var models: URL { root.appendingPathComponent("models", isDirectory: true) }
    var downloads: URL { root.appendingPathComponent(".downloads", isDirectory: true) }
    var cache: URL { root.appendingPathComponent("audio-cache", isDirectory: true) }
    var clips: URL { root.appendingPathComponent("clips", isDirectory: true) }
    var voiceFile: URL { root.appendingPathComponent("voice.bin") }
    var voices: URL { root.appendingPathComponent("voices", isDirectory: true) }
    func modelDirectory(_ profile: ModelProfile) -> URL { models.appendingPathComponent(profile.directory, isDirectory: true) }

    /// Operator contact shown in Settings (set VOICECLONE_CONTACT in project.yml before a store release).
    static var contact: String { (Bundle.main.object(forInfoDictionaryKey: "VoiceCloneContact") as? String) ?? "" }
    /// Repository that hosts the public model packs (same as the Android app).
    static var modelRepository: String { (Bundle.main.object(forInfoDictionaryKey: "VoiceCloneModelRepository") as? String) ?? "555734/555734.github.io" }
}
