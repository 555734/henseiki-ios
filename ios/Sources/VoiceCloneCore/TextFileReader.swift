import Foundation

/// Turns a text-like file the user picked (txt, md, html, subtitles ... in UTF-8, UTF-16, Shift_JIS, EUC-JP or JIS)
/// into plain text that can be read aloud. Files that are clearly not text (PDF, Word, EPUB, binaries) are refused
/// with a message. Very long files are cut at a sentence end at [maxChars]. (Port of the Android `TextFileReader`.)
public enum TextFileReader {
    public static let maxChars = 20_000
    public static let maxBytes = 4 * 1024 * 1024
    private static let notText = "テキストファイルではないようです。txt・md・htmlなどの文章ファイルを選んでください"

    public struct NotTextError: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }
    public struct Loaded: Equatable { public let text: String; public let truncated: Bool }

    /// Reads at most [maxBytes] of [url]; the flag tells whether the file was longer than that.
    public static func readBytes(from url: URL) throws -> (data: Data, cut: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maxBytes)
        let more = handle.readData(ofLength: 1)
        return (data, !more.isEmpty)
    }

    public static func load(_ data: Data, name: String = "", cut: Bool = false) throws -> Loaded {
        let bytes = [UInt8](data)
        if bytes.starts(with: Array("%PDF".utf8)) { throw NotTextError(message: "PDFは読み込めません。txt・md・htmlなどの文章ファイルを選んでください") }
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) { throw NotTextError(message: "Word・EPUBなどは読み込めません。txt・md・htmlなどの文章ファイルを選んでください") }
        var text = try decode(bytes, cut: cut)
        switch (name as NSString).pathExtension.lowercased() {
        case "html", "htm", "xhtml": text = stripHTML(text)
        case "md", "markdown": text = stripMarkdown(text)
        default: break
        }
        text = normalize(text)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw NotTextError(message: "読み上げできる文章が見つかりませんでした") }
        return truncate(text, cut: cut)
    }

    private static func decode(_ bytes: [UInt8], cut: Bool) throws -> String {
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            return String(decoding: bytes[3...], as: UTF8.self)
        }
        if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE, let s = String(data: Data(bytes[2...]), encoding: .utf16LittleEndian) { return s }
        if bytes.count >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF, let s = String(data: Data(bytes[2...]), encoding: .utf16BigEndian) { return s }
        if bytes.contains(0) { throw NotTextError(message: notText) }
        if usesJISEscapes(bytes), let s = String(data: Data(bytes), encoding: .iso2022JP) { return s }
        let utf8Bytes = cut ? withoutIncompleteTail(bytes) : bytes
        if let s = String(data: Data(utf8Bytes), encoding: .utf8) { return s }
        // Legacy Japanese encodings: decode with each and keep the one that looks least like garbage.
        let guesses = [String.Encoding.shiftJIS, .japaneseEUC].compactMap { encoding -> (String, Int)? in
            guard let s = String(data: Data(bytes), encoding: encoding) else { return nil }
            return (s, penalty(s))
        }
        guard let best = guesses.min(by: { $0.1 < $1.1 }), Double(best.1) <= Double(best.0.unicodeScalars.count) * 0.2 else {
            throw NotTextError(message: notText)
        }
        return best.0
    }

    private static func usesJISEscapes(_ bytes: [UInt8]) -> Bool {
        guard bytes.count > 1 else { return false }
        for i in 0..<(bytes.count - 1) where bytes[i] == 0x1B && (bytes[i + 1] == UInt8(ascii: "$") || bytes[i + 1] == UInt8(ascii: "(")) { return true }
        return false
    }

    /// Half-width katakana and replacement characters mean the wrong legacy encoding was guessed.
    private static func penalty(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { sum, c in
            if c.value == 0xFFFD { return sum + 20 }
            if c.value >= 0xFF61 && c.value <= 0xFF9F { return sum + 5 }
            return sum
        }
    }

    /// Drops the last (possibly cut-off) UTF-8 character so a file cut at [maxBytes] still decodes strictly.
    private static func withoutIncompleteTail(_ bytes: [UInt8]) -> [UInt8] {
        var end = bytes.count
        var continuation = 0
        while end > 0 && continuation < 4 && (bytes[end - 1] & 0xC0) == 0x80 { end -= 1; continuation += 1 }
        if end > 0 && (bytes[end - 1] & 0xC0) == 0xC0 { end -= 1 }
        return Array(bytes[0..<end])
    }

    private static func normalize(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0}", with: "").replacingOccurrences(of: "\u{FEFF}", with: "")
        t = replace(t, "[ \\t\\u3000]+\\n", "\n")
        t = replace(t, "\\n{3,}", "\n\n")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncate(_ text: String, cut: Bool) -> Loaded {
        let scalars = Array(text.unicodeScalars)
        if scalars.count <= maxChars { return Loaded(text: text, truncated: cut) }
        let head = Array(scalars[0..<maxChars])
        let enders: Set<UInt32> = [0x3002, 0xFF01, 0xFF1F, 0x21, 0x3F, 0x0A]
        let sentenceEnd = head.lastIndex { enders.contains($0.value) }
        let end = (sentenceEnd ?? -1) >= maxChars * 8 / 10 ? sentenceEnd! + 1 : maxChars
        var view = String.UnicodeScalarView()
        view.append(contentsOf: head[0..<end])
        return Loaded(text: String(view).trimmingCharacters(in: .whitespacesAndNewlines), truncated: true)
    }

    static func stripHTML(_ html: String) -> String {
        var text = replace(html, "<(script|style|head)\\b[^>]*>[\\s\\S]*?</\\1\\s*>", " ", options: [.caseInsensitive])
        text = replace(text, "<br\\s*/?>|</(p|div|h[1-6]|li|tr|blockquote)\\s*>", "\n", options: [.caseInsensitive])
        text = replace(text, "<[^>]*>", "")
        text = replaceNumeric(text, "&#x([0-9a-fA-F]+);", radix: 16)
        text = replaceNumeric(text, "&#(\\d+);", radix: 10)
        return text.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    static func stripMarkdown(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.map { line in
            var l = line
            l = replace(l, "^\\s{0,3}#{1,6}\\s+", "")
            l = replace(l, "^\\s*>+\\s?", "")
            l = replace(l, "^\\s*([-*+]|\\d+\\.)\\s+", "")
            l = replace(l, "!\\[[^\\]]*\\]\\([^)]*\\)", "")
            l = replace(l, "\\[([^\\]]+)\\]\\([^)]*\\)", "$1")
            return replace(l, "[*_`]{1,3}", "")
        }.joined(separator: "\n")
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String, options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func replaceNumeric(_ text: String, _ pattern: String, radix: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let digits = Range(match.range(at: 1), in: text) else { continue }
            result += text[last..<whole.lowerBound]
            if let value = UInt32(text[digits], radix: radix), let scalar = Unicode.Scalar(value) { result.unicodeScalars.append(scalar) }
            last = whole.upperBound
        }
        return result + text[last...]
    }
}
