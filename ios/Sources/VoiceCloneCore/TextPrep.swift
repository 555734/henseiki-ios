import Foundation

/// Text preparation for synthesis. Same behaviour as the Android `IrodoriEngine.normalizeText` / `splitSentences`.
public enum TextPrep {
    /// Subset of irodori_tts.text_normalization sufficient for plain prose.
    public static func normalize(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\t", with: "").replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "？", with: "?").replacingOccurrences(of: "！", with: "!")
        t = t.precomposedStringWithCompatibilityMapping // NFKC
        return t.replacingOccurrences(of: "...", with: "…").replacingOccurrences(of: "..", with: "…")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split long input into sentences after 。！？!? and newlines.
    public static func splitSentences(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "[^。！？!?\\n]+[。！？!?]*") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match -> String? in
            guard let r = Range(match.range, in: text) else { return nil }
            let s = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
    }
}

public enum SavedAudioName {
    /// File name for saved speech: date, time and the beginning of the text, e.g. VoiceClone_20261110_1435_船の中からでは.wav
    public static func make(text: String, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd_HHmm"
        let unsafe = CharacterSet(charactersIn: "\\/:*?\"<>|。、，．,.!?！？「」『』（）()・").union(.controlCharacters).union(.whitespacesAndNewlines)
        let snippet = String(String.UnicodeScalarView(text.unicodeScalars.filter { !unsafe.contains($0) })).prefix(16)
        return "VoiceClone_" + formatter.string(from: now) + (snippet.isEmpty ? "" : "_\(snippet)") + ".wav"
    }
}

public enum RecordingPrompts {
    /// The first lines are enough to register a voice (about 30 s); the rest are optional extras.
    public static let registration = 6
    public static let lines = [
        "今日はとてもいい天気なので、近くの公園まで散歩に行こうと思います。",
        "駅前の小さなパン屋さんでは、毎朝焼きたてのクロワッサンが並びます。",
        "来週の会議の資料は、金曜日の夕方までに皆さんへお送りします。",
        "昔々、ある山奥の村に、心の優しい若者が住んでいました。",
        "えっ、本当ですか？それはすごく嬉しいニュースですね！",
        "ありがとうございます。またお会いできるのを楽しみにしています。",
        "台風の影響で、明日の新幹線は始発から運転を見合わせる予定です。",
        "このスープには、玉ねぎとにんじんとじゃがいもがたっぷり入っています。",
        "すみません、この近くに郵便局はありますか？",
        "週末は家族と一緒に、海の見えるキャンプ場へ出かけました。",
        "彼女は静かにうなずいて、窓の外の雪景色を眺めていた。",
        "まずは電源ボタンを長押しして、画面が明るくなるまで待ってください。",
        "うわぁ、すごい！こんなにきれいな夕焼け、初めて見たよ。",
        "残念ながら、今回のプロジェクトは予算の都合で延期になりました。",
        "図書館で借りた本の返却期限は、来週の水曜日までです。",
    ]
}
