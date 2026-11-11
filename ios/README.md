# VoiceClone for iOS

The iPhone/iPad version of the app (same speech model, same look, same terms as the Android app).

```
ios/
  Package.swift            Swift package "VoiceCloneCore" (plain Swift, runs on Linux and macOS)
  Sources/VoiceCloneCore/  tokenizer, audio DSP, sampler, speech engine, voice library, model pack checks, text reader
  Tests/                   42 tests, including checks against the Android (Kotlin) code on the same inputs
  App/                     the iOS app: SwiftUI screens, ONNX Runtime, microphone, playback, background download
  project.yml              XcodeGen spec that generates VoiceClone.xcodeproj
  scripts/                 fixture generators, Kotlin golden-output harness, legal-text generator
```

## What has been checked, and what has not

| Part | Status |
|---|---|
| `VoiceCloneCore` (all logic) | Built and tested on Linux with Swift 6.0 (`swift test`, 42 tests). |
| Same results as Android | The tokenizer, text preparation, loudness/resampling/padding/trimming maths and the noise generator are compared with the real Android code on the same inputs (`ParityTests`, fixtures made by `scripts/kotlin_golden`). |
| Speech pipeline order, chunking, guidance, cancellation | Tested with a fake graph runner (`EngineTests`). |
| Model pack download/verify/install | Tested with tiny packs including a ZIP64 one (`ModelPackTests`). |
| **`App/` (screens, ONNX Runtime, audio, download)** | **Syntax-checked only.** It needs Xcode and Apple's frameworks, which are not available on the Linux machine this was written on, so it has never been compiled or run. Expect to fix a few small compile errors on the first Mac build, and test on a real iPhone. |
| Speed | **Not measured.** No iPhone speed claim is made. |

## Build on a Mac

Requirements: macOS with Xcode 15 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
cd ios
swift test                       # core tests
xcodegen generate                # creates VoiceClone.xcodeproj
open VoiceClone.xcodeproj        # choose your Team under Signing & Capabilities, pick your iPhone, Run
```

ONNX Runtime comes from the official Swift package (`microsoft/onnxruntime-swift-package-manager`), resolved by Xcode.
Set `VoiceCloneContact` in `project.yml` to your support address before a store release (it is shown in Settings).

## Without a paid Apple account

An Apple ID is enough to run the app on your own iPhone from Xcode (the install expires after 7 days).
The GitHub workflow `.github/workflows/ios.yml` also produces an **unsigned** `VoiceClone-unsigned.ipa`; tools such as
AltStore or Sideloadly can sign it with a free Apple ID.

## App Store

You need the Apple Developer Program (paid), a bundle ID you own (change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`),
a public URL for the privacy policy (the text is in `LegalTexts` / Settings), the App Privacy answers
("Data Not Collected": the app sends no personal data; models are downloaded from GitHub), screenshots, and review.
The microphone usage text, the privacy manifest (`App/Resources/PrivacyInfo.xcprivacy`) and the in-app terms agreement are included.
Apple may ask how voice cloning misuse is prevented: the app asks for agreement to the terms (own voice or permission only)
and asks again before the first recording.

## Differences from Android (version 1)

* Original decoder only: no "speed first" light decoder, no mode switch. Speed on iPhone is unmeasured.
* One model (MF mixed8, about 1.1 GB, downloaded once from the same public release as Android). No legacy model, no RF.
* No "additional training" export/import screen, and no reuse cache for generated audio.
* Everything else is the same: free-talk or six-line voice registration, audio-file import, several voices with one-tap switching,
  text-file import (txt/md/html, auto charset), full-screen player with background playback, save to Files, share,
  terms and privacy policy, delete-all-data.
* Generation continues in the background while its audio is playing (iOS keeps an audio app running); the model download uses
  a background URL session, so it continues even when the app is closed.

`voice.bin` has the same binary format as Android's.
