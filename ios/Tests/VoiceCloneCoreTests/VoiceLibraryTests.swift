import XCTest
@testable import VoiceCloneCore

final class VoiceLibraryTests: XCTestCase {
    private var root: URL!
    private var active: URL!
    private var library: VoiceLibrary!

    override func setUp() {
        root = makeTemporaryDirectory()
        active = root.appendingPathComponent("voice.bin")
        library = VoiceLibrary(directory: root.appendingPathComponent("voices"), activeFile: active)
    }

    private func voice(_ seed: Float, seconds: Float = 30) -> Data {
        Voice(state: (0..<(2 * speakerDim)).map { seed + Float($0) * 0.001 }, len: 2, mask: [1, 1], refSeconds: seconds).encoded()
    }

    func testAnExistingVoiceFileBecomesTheFirstEntry() throws {
        XCTAssertTrue(library.list().isEmpty)
        try voice(1).write(to: active)
        let voices = library.list()
        XCTAssertEqual(voices.count, 1)
        XCTAssertEqual(voices[0].name, "声 1"); XCTAssertEqual(voices[0].refSeconds, 30)
        XCTAssertEqual(library.activeId(), voices[0].id)
    }

    func testEachNewVoiceIsKeptAndOneTapSwitchesBack() throws {
        try voice(1).write(to: active); let first = library.sync(source: "registered")!
        try voice(2).write(to: active); let second = library.sync(source: "registered")!
        try voice(3, seconds: 12).write(to: active); let imported = library.sync(source: "imported")!
        XCTAssertEqual(library.list().map { $0.name }, ["声 1", "声 2", "取り込んだ声 1"])
        XCTAssertEqual(library.activeId(), imported.id); XCTAssertEqual(imported.refSeconds, 12)
        library.activate(first.id)
        XCTAssertEqual(try Data(contentsOf: active), voice(1)); XCTAssertEqual(library.activeId(), first.id)
        library.activate(second.id)
        XCTAssertEqual(try Data(contentsOf: active), voice(2))
        XCTAssertNil(library.activate("missing")); XCTAssertEqual(try Data(contentsOf: active), voice(2))
    }

    func testInstallingTheSameVoiceAgainSelectsTheExistingEntry() throws {
        try voice(1).write(to: active); let first = library.sync(source: "registered")!
        try voice(2).write(to: active); library.sync(source: "registered")
        try voice(1).write(to: active)
        XCTAssertEqual(library.sync(source: "registered")!.id, first.id)
        XCTAssertEqual(library.list().count, 2)
    }

    func testRenameAndDelete() throws {
        try voice(1).write(to: active); let first = library.sync(source: "registered", now: Date(timeIntervalSince1970: 1000))!
        try voice(2).write(to: active); let second = library.sync(source: "registered", now: Date(timeIntervalSince1970: 2000))!
        XCTAssertTrue(library.rename(second.id, to: "  母の声  "))
        XCTAssertEqual(library.list().first { $0.id == second.id }?.name, "母の声")
        XCTAssertFalse(library.rename(second.id, to: "   "))
        library.rename(first.id, to: String(repeating: "あ", count: 50))
        XCTAssertEqual(library.list().first { $0.id == first.id }?.name.count, VoiceLibrary.maxNameLength)
        // deleting the active voice makes the other one active
        XCTAssertEqual(library.delete(second.id)?.id, first.id)
        XCTAssertEqual(library.activeId(), first.id); XCTAssertEqual(try Data(contentsOf: active), voice(1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("voices/\(second.id).bin").path))
        // deleting the last voice removes the active file
        XCTAssertNil(library.delete(first.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.path)); XCTAssertTrue(library.list().isEmpty)
    }

    func testClearRemovesEverythingAndABrokenIndexIsRebuilt() throws {
        try voice(1).write(to: active); library.sync(source: "registered")
        try "{ not json".write(to: root.appendingPathComponent("voices/index.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(library.list().count, 1)
        library.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.path)); XCTAssertTrue(library.list().isEmpty)
    }
}
