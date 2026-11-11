import Foundation
import XCTest
@testable import VoiceCloneCore

enum Fixture {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
    }
    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }
    static func json(_ name: String) throws -> Any { try JSONSerialization.jsonObject(with: data(name)) }
}

func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vc-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func assertClose(_ a: Double, _ b: Double, tolerance: Double = 1e-4, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a, b, accuracy: max(tolerance, abs(b) * tolerance), message, file: file, line: line)
}
