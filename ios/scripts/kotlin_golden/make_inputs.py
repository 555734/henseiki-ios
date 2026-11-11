#!/usr/bin/env python3
"""Inputs for the Kotlin/Swift parity check: a synthetic Unigram vocabulary and sentences. (No real model is needed.)"""
import json
from pathlib import Path

OUT = Path(__file__).resolve().parents[2] / "Tests/VoiceCloneCoreTests/Fixtures"

pieces = [["<unk>", 0.0], ["<s>", 0.0], ["</s>", 0.0]]
for b in range(256):
    if b == 0xF0:  # 4-byte UTF-8 (emoji) has no byte piece -> falls back to <unk>
        continue
    pieces.append(["<0x%02X>" % b, -10.0])
words = {
    "▁": -4.0, "▁今日": -6.0, "今日": -6.5, "は": -3.0, "とても": -5.5, "いい": -5.0, "天気": -6.0, "です": -4.5, "。": -2.5, "、": -2.6,
    "こんにちは": -7.0, "こん": -8.0, "にち": -8.5, "ちは": -9.0, "私": -5.0, "の": -2.0, "声": -5.5, "を": -2.2, "使": -6.0, "って": -4.0,
    "東京": -8.0, "大学": -8.5, "病院": -9.0, "東京大学病院": -14.0, "大学病院": -13.5, "ありがとう": -9.5, "ございます": -10.5,
    "ありがとうございます": -14.5, "あり": -7.5, "がと": -9.0, "う": -4.0, "ご": -5.0, "ざ": -6.0, "い": -3.5, "ま": -4.0, "す": -4.5,
    "テスト": -8.0, "データ": -8.2, "A": -6.0, "B": -6.1, "hello": -9.0, "▁hello": -8.5, "▁world": -8.7, "world": -9.1, "H": -7.0, "e": -6.0,
    "l": -6.0, "o": -6.0, "1": -6.5, "2": -6.5, "3": -6.5, "!": -5.0, "?": -5.0, "…": -6.0, "ー": -5.0, "ー」": -9.0,
    "お": -4.5, "は": -3.0, "よう": -6.5, "おはよう": -9.0, "ございま": -12.0, "ひらがなだけの長い言葉": -15.0,
}
for piece, score in words.items():
    pieces.append([piece, score])
(OUT / "tokenizer_synthetic.json").write_text(json.dumps({"model": {"type": "Unigram", "vocab": pieces}}, ensure_ascii=False), encoding="utf-8")

texts = [
    "今日はとてもいい天気です。", "こんにちは", "私の声を使って", "東京大学病院", "ありがとうございます", "ひらがなだけの長い言葉",
    "hello world", "Hello World!", "A B テスト データ", "1 2 3", "😀", "今日😀はいい天気", "", " ", "   ", "テスト  データ", "ｱｲｳ", "ＡＢＣ",
    "おはようございます。今日もいい天気ですね？", "漢字かな交じり文。", "　全角スペース", "abc\ndef", "…。、", "ーー", "声声声声声", "東京東京大学大学病院病院",
    "emoji😀🙂 mixed 東京", "ありがとうございま", "𠮷野家", "é", "ñandú",
]
(OUT / "tokenizer_texts.json").write_text(json.dumps(texts, ensure_ascii=False), encoding="utf-8")

prep = [
    "こんにちは。今日は晴れです。", "Hello?  World!\t", "うれしい！！　本当に？", "ｱｲｳＡＢＣ１２３", "a...b..c", "  前後の空白  ", "一行目。\n二行目！\n\n三行目？四行目", "",
    "「かぎ括弧」。（括弧）！", "文末なし", "。。。", "a　b", "①②③", "ﾊﾟﾝ", "㈱テスト",
]
(OUT / "text_prep_texts.json").write_text(json.dumps(prep, ensure_ascii=False), encoding="utf-8")
print("inputs written to", OUT)
