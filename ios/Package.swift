// swift-tools-version:5.9
import PackageDescription

// VoiceCloneCore is plain Swift (Foundation only): the speech pipeline, voice library, model pack checks and text
// helpers. It builds and its tests run on Linux as well as on macOS, so the logic is checked without an iPhone.
// The iOS app (App/) adds the screens, the microphone, playback and ONNX Runtime on top of it.
let package = Package(
    name: "VoiceClone",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "VoiceCloneCore", targets: ["VoiceCloneCore"])],
    targets: [
        .target(name: "VoiceCloneCore"),
        .testTarget(name: "VoiceCloneCoreTests", dependencies: ["VoiceCloneCore"], resources: [.copy("Fixtures")]),
    ]
)
