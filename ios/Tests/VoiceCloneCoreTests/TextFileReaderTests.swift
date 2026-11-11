import XCTest
@testable import VoiceCloneCore

final class TextFileReaderTests: XCTestCase {
    private let sample = "吾輩は猫である。名前はまだ無い。\nどこで生れたかとんと見当がつかぬ。"
    private func load(_ bytes: [UInt8], name: String = "a.txt", cut: Bool = false) throws -> TextFileReader.Loaded { try TextFileReader.load(Data(bytes), name: name, cut: cut) }

    func testUTF8WithAndWithoutBOMAndUTF16() throws {
        XCTAssertEqual(try load(Array(sample.utf8)).text, sample)
        XCTAssertEqual(try load([0xEF, 0xBB, 0xBF] + Array(sample.utf8)).text, sample)
        XCTAssertEqual(try TextFileReader.load([0xFF, 0xFE] .withData(sample.data(using: .utf16LittleEndian)!)).text, sample)
        XCTAssertEqual(try TextFileReader.load([0xFE, 0xFF].withData(sample.data(using: .utf16BigEndian)!)).text, sample)
    }

    func testLegacyJapaneseEncodingsAreDetected() throws {
        #if canImport(Darwin)
        XCTAssertEqual(try load(Array(sample.data(using: .shiftJIS)!)).text, sample)
        XCTAssertEqual(try load(Array(sample.data(using: .japaneseEUC)!)).text, sample)
        XCTAssertEqual(try load(Array(sample.data(using: .iso2022JP)!)).text, sample)
        #else
        // swift-corelibs-foundation on Linux may lack the Japanese converters; the iOS build is where this matters.
        if let sjis = sample.data(using: .shiftJIS) { XCTAssertEqual(try load(Array(sjis)).text, sample) }
        #endif
    }

    func testLineEndingsAndBlankRunsAreTidied() throws {
        XCTAssertEqual(try load(Array("一行目。  \r\n\r\n\r\n\r\n二行目。\r\n".utf8)).text, "一行目。\n\n二行目。")
    }

    func testHTMLAndMarkdownAreReducedToText() throws {
        let html = "<html><head><title>x</title><style>p{}</style></head><body><h1>題</h1><p>本文&amp;続き。<br>改行&#12354;</p><script>var a=1;</script></body></html>"
        XCTAssertEqual(try load(Array(html.utf8), name: "page.html").text, "題\n本文&続き。\n改行あ")
        let markdown = "# 見出し\n\n- 項目**強調**\n[リンク](http://example.com)です。\n```\ncode\n```\n"
        let text = try load(Array(markdown.utf8), name: "note.md").text
        XCTAssertTrue(text.contains("見出し") && text.contains("項目強調") && text.contains("リンクです。"), text)
        XCTAssertFalse(text.contains("http") || text.contains("#") || text.contains("```") || text.contains("**"), text)
    }

    func testFilesThatAreNotTextAreRefusedWithAReason() {
        for bytes in [Array("%PDF-1.7 ...".utf8), [UInt8(ascii: "P"), UInt8(ascii: "K"), 3, 4, 1, 2], (0..<64).map { UInt8($0 % 7) }] {
            XCTAssertThrowsError(try load(bytes)) { error in
                XCTAssertTrue(error is TextFileReader.NotTextError)
                XCTAssertTrue((error as! TextFileReader.NotTextError).message.contains("txt"))
            }
        }
        XCTAssertThrowsError(try load(Array("   \n  ".utf8)))
    }

    func testLongTextIsCutAtASentenceEnd() throws {
        let loaded = try load(Array(String(repeating: "これは長い文です。", count: 5000).utf8))
        XCTAssertTrue(loaded.truncated)
        XCTAssertLessThanOrEqual(loaded.text.unicodeScalars.count, TextFileReader.maxChars)
        XCTAssertTrue(loaded.text.hasSuffix("。"))
        XCTAssertFalse(try load(Array(sample.utf8)).truncated)
    }

    func testAFileCutInTheMiddleOfACharacterStillDecodes() throws {
        let bytes = Array(Array("あいう".utf8).prefix(7)) // 3 + 3 + 1 byte of the third character
        let loaded = try load(bytes, cut: true)
        XCTAssertEqual(loaded.text, "あい"); XCTAssertTrue(loaded.truncated)
    }

    func testReadBytesStopsAtTheLimitAndReportsIt() throws {
        let file = makeTemporaryDirectory().appendingPathComponent("big.txt")
        try Data(repeating: 97, count: TextFileReader.maxBytes + 10).write(to: file)
        let (data, cut) = try TextFileReader.readBytes(from: file)
        XCTAssertEqual(data.count, TextFileReader.maxBytes); XCTAssertTrue(cut)
        let small = makeTemporaryDirectory().appendingPathComponent("s.txt"); try Data(repeating: 97, count: 10).write(to: small)
        XCTAssertFalse(try TextFileReader.readBytes(from: small).cut)
    }
}

private extension Array where Element == UInt8 {
    func withData(_ data: Data) -> Data { Data(self) + data }
}
private extension TextFileReader {
    static func load(_ data: Data) throws -> Loaded { try load(data, name: "a.txt", cut: false) }
}
