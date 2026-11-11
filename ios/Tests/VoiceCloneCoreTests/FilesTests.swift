import XCTest
@testable import VoiceCloneCore

final class FilesTests: XCTestCase {
    func testWavFileWriterProducesAValidFileFromPieces() throws {
        let url = makeTemporaryDirectory().appendingPathComponent("out.wav")
        let writer = try WavFileWriter(url: url)
        try writer.append([0, 0.5, -1])
        try writer.append([2, -0.25])
        try writer.close(); try writer.close()
        XCTAssertEqual(writer.samples, 5)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data, AudioDsp.wavData([0, 0.5, -1, 2, -0.25])) // identical to writing it in one go
        XCTAssertEqual(writer.seconds, 5.0 / 48000, accuracy: 1e-9)
    }

    func testClipStoreKeepsOrderAndTotals() throws {
        let store = ClipStore(directory: makeTemporaryDirectory().appendingPathComponent("clips"))
        XCTAssertTrue(store.list().isEmpty); XCTAssertEqual(store.seconds(), 0)
        try store.add([Float](repeating: 0.1, count: 48000))
        try store.add([Float](repeating: 0.2, count: 24000))
        XCTAssertEqual(store.list().map { $0.lastPathComponent }, ["clip_000.f32", "clip_001.f32"])
        XCTAssertEqual(store.seconds(), 1.5, accuracy: 1e-9)
        XCTAssertEqual(try store.load().map { $0.count }, [48000, 24000])
        XCTAssertEqual(try store.load()[1][0], 0.2)
        store.removeLast()
        try store.add([0.3])
        XCTAssertEqual(store.list().map { $0.lastPathComponent }, ["clip_000.f32", "clip_001.f32"]) // numbering continues after the last kept clip
        store.clear()
        XCTAssertTrue(store.list().isEmpty)
    }
}
