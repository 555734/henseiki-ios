import Foundation

/// Swift port of the Hugging Face `tokenizers` Unigram encoder for Irodori-TTS (modernbert-ja vocabulary: no
/// normalizer, Metaspace(prepend=never, split=false), byte fallback), plus Irodori's inference-time rare-token split:
/// pieces with >= 4 characters and log-prob <= -13 (hiragana-only pieces excepted) get score -1e9, so Viterbi falls
/// back to shorter, better-trained pieces. Same behaviour as the Android `UnigramTokenizer`.
public final class UnigramTokenizer {
    private var ids = [String: Int]()
    private var scores: [Double]
    private let maxLen: Int
    private let unkScore: Double
    public let bosId: Int
    private let unkId = 0

    private static let rareThreshold = -13.0
    private static let rareMinChars = 4
    private static let unkPenalty = 10.0

    private static func isHiraganaOnly(_ scalars: String.UnicodeScalarView) -> Bool {
        !scalars.isEmpty && scalars.allSatisfy { ($0.value >= 0x3041 && $0.value <= 0x3096) || $0.value == 0x309D || $0.value == 0x309E || $0.value == 0x30FC }
    }

    public init(pieces: [(String, Double)], rareSplit: Bool = true) {
        scores = [Double](repeating: 0, count: pieces.count)
        ids.reserveCapacity(pieces.count * 2)
        var maxL = 1
        var minScore = Double.greatestFiniteMagnitude
        for (i, entry) in pieces.enumerated() {
            let piece = entry.0
            var s = entry.1
            if rareSplit {
                let text = piece.replacingOccurrences(of: "▁", with: "").unicodeScalars
                if s <= UnigramTokenizer.rareThreshold && text.count >= UnigramTokenizer.rareMinChars && !UnigramTokenizer.isHiraganaOnly(text) { s = -1e9 }
            }
            scores[i] = s
            if s < minScore { minScore = s }
            if ids[piece] == nil { ids[piece] = i }
            maxL = max(maxL, piece.unicodeScalars.count)
        }
        maxLen = maxL
        unkScore = minScore - UnigramTokenizer.unkPenalty
        bosId = pieces.firstIndex { $0.0 == "<s>" } ?? -1
    }

    public static func load(_ url: URL, rareSplit: Bool = true) throws -> UnigramTokenizer {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard let vocab = (root?["model"] as? [String: Any])?["vocab"] as? [[Any]] else { throw EngineError.message("tokenizer.json が不正です") }
        var pieces = [(String, Double)]()
        pieces.reserveCapacity(vocab.count)
        for entry in vocab {
            guard entry.count >= 2, let piece = entry[0] as? String, let score = (entry[1] as? NSNumber)?.doubleValue else { throw EngineError.message("tokenizer.json が不正です") }
            pieces.append((piece, score))
        }
        return UnigramTokenizer(pieces: pieces, rareSplit: rareSplit)
    }

    /// Token ids without special tokens (the caller prepends BOS).
    public func encode(_ text: String) -> [Int] {
        if text.isEmpty { return [] }
        let cps = Array(text.replacingOccurrences(of: " ", with: "▁").unicodeScalars)
        let n = cps.count
        var best = [Double](repeating: -Double.infinity, count: n + 1)
        var backLen = [Int](repeating: 0, count: n + 1)
        var backId = [Int](repeating: 0, count: n + 1)
        best[0] = 0
        for start in 0..<n {
            if best[start] == -Double.infinity { continue }
            var hasSingle = false
            var len = 1
            while len <= min(maxLen, n - start) {
                var piece = String.UnicodeScalarView()
                piece.append(contentsOf: cps[start..<(start + len)])
                if let id = ids[String(piece)] {
                    if len == 1 { hasSingle = true }
                    let s = best[start] + scores[id]
                    if s > best[start + len] { best[start + len] = s; backLen[start + len] = len; backId[start + len] = id }
                }
                len += 1
            }
            if !hasSingle {
                let s = best[start] + unkScore
                if s > best[start + 1] { best[start + 1] = s; backLen[start + 1] = 1; backId[start + 1] = unkId }
            }
        }
        // backtrack into (id, codepoint span) pieces, fusing consecutive unknowns
        var rev = [(id: Int, from: Int, to: Int)]()
        var end = n
        while end > 0 {
            let len = backLen[end]
            rev.append((backId[end], end - len, end))
            end -= len
        }
        rev.reverse()
        var out = [Int]()
        out.reserveCapacity(rev.count)
        var i = 0
        while i < rev.count {
            if rev[i].id != unkId { out.append(rev[i].id); i += 1; continue }
            var j = i
            while j + 1 < rev.count && rev[j + 1].id == unkId { j += 1 }
            // byte fallback: <0xXX> per UTF-8 byte when every byte piece exists, else <unk>
            var span = String.UnicodeScalarView()
            span.append(contentsOf: cps[rev[i].from..<rev[j].to])
            let byteIds = Array(String(span).utf8).map { ids[String(format: "<0x%02X>", Int($0))] }
            if byteIds.allSatisfy({ $0 != nil }) { out.append(contentsOf: byteIds.map { $0! }) } else { out.append(unkId) }
            i = j + 1
        }
        return out
    }
}
