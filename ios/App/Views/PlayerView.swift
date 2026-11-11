import SwiftUI
import UniformTypeIdentifiers
import VoiceCloneCore

/// A WAV file the user can save to Files.
struct WavDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.wav] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Full-screen player in the style of a music app: artwork, title, seek bar, transport controls, then save and share.
struct PlayerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlayerContent(player: model.player, title: model.lastAudioTitle, url: model.lastAudio, fileName: model.suggestedFileName) { dismiss() }
    }
}

private struct PlayerContent: View {
    @ObservedObject var player: PlaybackController
    let title: String
    let url: URL?
    let fileName: String
    let close: () -> Void
    @State private var exporting = false
    @State private var document: WavDocument?
    @State private var scrubbing = false
    @State private var scrubPosition: Double = 0
    @State private var saveMessage = "保存先を選べます（ファイル）"

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Button(action: close) { Image(systemName: "chevron.down").font(.system(size: 20, weight: .semibold)).foregroundColor(Palette.ink).frame(width: 48, height: 48) }
                    .accessibilityLabel("閉じる")
                Spacer()
                Text("再生中").font(.system(size: 14)).foregroundColor(Palette.muted)
                Spacer()
                Color.clear.frame(width: 48, height: 48)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 28).fill(Color.white)
                RoundedRectangle(cornerRadius: 28).stroke(Palette.border, lineWidth: 1)
                MarkView(size: 180)
            }
            .aspectRatio(1, contentMode: .fit)
            VStack(alignment: .leading, spacing: 4) {
                Text(title.isEmpty ? "音声" : title).font(.system(size: 22, weight: .bold)).foregroundColor(Palette.ink).lineLimit(2)
                Text("VoiceClone ・ あなたの声").font(.system(size: 15)).foregroundColor(Palette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 4) {
                Slider(value: Binding(get: { scrubbing ? scrubPosition : player.position }, set: { scrubPosition = $0 }),
                       in: 0...max(player.duration, 0.1)) { editing in
                    scrubbing = editing
                    if !editing { player.seek(to: scrubPosition) }
                }
                .tint(Palette.primary)
                HStack {
                    Text(clock(scrubbing ? scrubPosition : player.position)); Spacer(); Text(clock(player.duration))
                }
                .font(.system(size: 13)).foregroundColor(Palette.muted)
            }
            HStack(spacing: 28) {
                Button { player.skip(-10) } label: { Image(systemName: "gobackward.10").font(.system(size: 30)).foregroundColor(Palette.ink) }
                    .accessibilityLabel("10秒戻る")
                Button { player.toggle() } label: {
                    ZStack {
                        Circle().fill(Palette.primary)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 32)).foregroundColor(.white)
                    }
                    .frame(width: 76, height: 76)
                }
                .accessibilityLabel(player.isPlaying ? "一時停止" : "再生")
                Button { player.skip(10) } label: { Image(systemName: "goforward.10").font(.system(size: 30)).foregroundColor(Palette.ink) }
                    .accessibilityLabel("10秒進む")
            }
            HStack(spacing: 40) {
                Button { prepareExport() } label: { actionLabel("square.and.arrow.down", "保存") }
                if let url { ShareLink(item: url) { actionLabel("square.and.arrow.up", "共有") } }
            }
            Text(saveMessage).font(.system(size: 13)).foregroundColor(Palette.muted)
            Spacer(minLength: 0)
        }
        .padding(24)
        .background(Color.white.ignoresSafeArea())
        .fileExporter(isPresented: $exporting, document: document, contentType: .wav, defaultFilename: fileName) { result in
            switch result {
            case .success: saveMessage = "保存しました"
            case .failure: saveMessage = "保存できませんでした"
            }
        }
    }

    private func actionLabel(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundColor(Palette.ink)
                .frame(width: 56, height: 56).background(Circle().fill(Palette.secondary))
            Text(title).font(.system(size: 13)).foregroundColor(Palette.ink)
        }
    }

    private func prepareExport() {
        guard let url, let data = try? Data(contentsOf: url) else { saveMessage = "音声を読み込めませんでした"; return }
        document = WavDocument(data: data)
        exporting = true
    }
}
