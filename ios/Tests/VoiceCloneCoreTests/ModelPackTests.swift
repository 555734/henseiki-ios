import XCTest
@testable import VoiceCloneCore

final class ModelPackTests: XCTestCase {
    func testManifestIsValidatedStrictly() throws {
        let data = try Fixture.data("pack_manifest.json")
        XCTAssertEqual(try ModelPack.readManifest(data, expected: .mfMixed8).files.count, 8)
        XCTAssertThrowsError(try ModelPack.readManifest(data, expected: .rfMixed8)) // wrong model
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["deterministic_encoder"] = false
        XCTAssertThrowsError(try ModelPack.readManifest(JSONSerialization.data(withJSONObject: json), expected: .mfMixed8))
        json["deterministic_encoder"] = true
        var files = json["files"] as! [[String: Any]]; files[0]["sha256"] = "XYZ"; json["files"] = files
        XCTAssertThrowsError(try ModelPack.readManifest(JSONSerialization.data(withJSONObject: json), expected: .mfMixed8))
        XCTAssertThrowsError(try ModelPack.readManifest(Data(), expected: .mfMixed8))
    }

    func testCatalogChecks() throws {
        let ok = #"{"format_version":1,"profile":"mf-mixed8","asset":"irodori-mf-mixed8.zip","size":1100000000,"unpacked_size":1200000000,"sha256":"\#(String(repeating: "a", count: 64))"}"#
        XCTAssertEqual(try ModelPack.parseCatalog(Data(ok.utf8), profile: .mfMixed8).size, 1_100_000_000)
        XCTAssertThrowsError(try ModelPack.parseCatalog(Data(ok.utf8), profile: .rfMixed8))
        XCTAssertThrowsError(try ModelPack.parseCatalog(Data(ok.replacingOccurrences(of: "1100000000", with: "3000000000").utf8), profile: .mfMixed8))
        XCTAssertEqual(ModelPack.downloadURL(.mfMixed8, repository: "o/r", name: "download.json").absoluteString,
                       "https://github.com/o/r/releases/download/models-mf-mixed8-v1/download.json")
    }

    private func install(_ name: String) throws -> (URL, Error?) {
        let root = makeTemporaryDirectory()
        do { try ModelPack.install(zip: Fixture.url(name), root: root, profile: .mfMixed8) } catch { return (root, error) }
        return (root, nil)
    }

    func testAStoredPackIsInstalledAndVerified() throws {
        let (root, error) = try install("pack_ok.zip")
        XCTAssertNil(error)
        let dir = root.appendingPathComponent(ModelProfile.mfMixed8.directory)
        XCTAssertTrue(ModelPack.isReady(dir, profile: .mfMixed8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("dacvae_decode.onnx").path))
        // a damaged file makes the install not ready
        try Data([0]).write(to: dir.appendingPathComponent("dit_step.onnx"))
        XCTAssertFalse(ModelPack.isReady(dir, profile: .mfMixed8))
        // no staging leftovers
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [])
    }

    func testZip64CentralDirectoryIsReadToo() throws {
        let (root, error) = try install("pack_zip64.zip")
        XCTAssertNil(error)
        XCTAssertTrue(ModelPack.isReady(root.appendingPathComponent(ModelProfile.mfMixed8.directory), profile: .mfMixed8))
    }

    func testBadPacksAreRejectedAndLeaveNothingBehind() throws {
        for name in ["pack_badhash.zip", "pack_deflated.zip", "pack_extra_file.zip", "pack_missing.zip"] {
            let (root, error) = try install(name)
            XCTAssertNotNil(error, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(ModelProfile.mfMixed8.directory).path), name)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") }, [], name)
        }
    }

    func testAnExistingInstallSurvivesAFailedUpdate() throws {
        let root = makeTemporaryDirectory()
        try ModelPack.install(zip: Fixture.url("pack_ok.zip"), root: root, profile: .mfMixed8)
        let dir = root.appendingPathComponent(ModelProfile.mfMixed8.directory)
        XCTAssertThrowsError(try ModelPack.install(zip: Fixture.url("pack_badhash.zip"), root: root, profile: .mfMixed8))
        XCTAssertTrue(ModelPack.isReady(dir, profile: .mfMixed8))
        XCTAssertThrowsError(try ModelPack.install(zip: Fixture.url("pack_ok.zip"), root: root, profile: .mfMixed8, validate: { _ in throw EngineError.message("unsupported") }))
        XCTAssertTrue(ModelPack.isReady(dir, profile: .mfMixed8))
    }

    func testInstallCanBeCancelled() {
        XCTAssertThrowsError(try ModelPack.install(zip: Fixture.url("pack_ok.zip"), root: makeTemporaryDirectory(), profile: .mfMixed8, cancelled: { true })) {
            XCTAssertEqual($0 as? EngineError, .cancelled)
        }
    }
}
