import SwiftUI
import UniformTypeIdentifiers
import VoiceCloneCore

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showPlayer: Bool
    @State private var confirmDownload = false
    @State private var importingText = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !model.modelReady { setupCard } else if !model.voiceReady { registerCard } else { readCard }
                if !model.status.isEmpty {
                    Text(model.status).font(.system(size: 13)).foregroundColor(Palette.muted).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .background(Color.white.ignoresSafeArea())
        .onAppear { model.refreshModelState(); model.refreshVoices() }
    }

    // MARK: first step: download the model once

    private var setupCard: some View {
        VStack(spacing: 14) {
            MarkView(size: 104).padding(.top, 12)
            Text("読み上げの準備をします").font(.system(size: 24, weight: .bold)).foregroundColor(Palette.ink)
            switch model.modelState {
            case .downloading(let fraction, let message):
                ProgressView(value: fraction).tint(Palette.primary)
                Text("\(message) \(Int(fraction * 100))%").font(.system(size: 14)).foregroundColor(Palette.muted)
                Text("画面を閉じても、他のアプリを使っていても進みます。").font(.system(size: 13)).foregroundColor(Palette.muted)
                Button("中止") { model.cancelModelDownload() }.buttonStyle(PillButtonStyle())
            case .installing(let message):
                ProgressView().tint(Palette.primary)
                Text(message).font(.system(size: 14)).foregroundColor(Palette.muted)
            case .failed(let message):
                Text(message).font(.system(size: 14)).foregroundColor(Palette.accent)
                Button("もう一度試す") { confirmDownload = true }.buttonStyle(PillButtonStyle(primary: true))
            default:
                Text("ダウンロードは最初の1回だけ。画面を閉じても進み、終わると、この案内は消えます。")
                    .font(.system(size: 14)).foregroundColor(Palette.muted).multilineTextAlignment(.center)
                Button("モデルの準備を始める") { confirmDownload = true }.buttonStyle(PillButtonStyle(primary: true))
            }
        }
        .frame(maxWidth: .infinity)
        .confirmationDialog("読み上げの準備", isPresented: $confirmDownload, titleVisibility: .visible) {
            Button("始める") { model.startModelDownload() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("約1.1 GBを取得します（Wi-Fi推奨）。最初の1回だけで、画面を閉じても続きます。")
        }
    }

    // MARK: second step: register a voice

    private var registerCard: some View {
        VStack(spacing: 14) {
            MarkView(size: 104).padding(.top, 12)
            Text("あなたの声を登録します").font(.system(size: 24, weight: .bold)).foregroundColor(Palette.ink)
            Text("好きなことを30秒ほど話すだけで登録できます。").font(.system(size: 14)).foregroundColor(Palette.muted)
            NavigationLink { VoiceView() } label: { Text("声を登録する") }.buttonStyle(PillButtonStyle(primary: true))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: everyday use: type or load text, then read it aloud

    private var readCard: some View {
        Card {
            Text("読ませる文章").font(.system(size: 17, weight: .medium)).foregroundColor(Palette.ink)
            if model.voices.count >= 2 { voiceChips }
            Button { importingText = true } label: { Text("ファイルから文章を読み込む") }.buttonStyle(PillButtonStyle())
            Text("txt・md・html（最大2万文字）").font(.system(size: 13)).foregroundColor(Palette.muted)
            TextEditor(text: $model.text)
                .font(.system(size: 18)).foregroundColor(Palette.ink)
                .frame(minHeight: 140)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.input))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.border, lineWidth: 1))
            if model.isBusy {
                Button { model.stopSpeaking() } label: { Text("音声を作っています…（タップで停止）") }.buttonStyle(PillButtonStyle(primary: true))
            } else {
                Button { model.speak() } label: { Text("この声で読み上げる") }.buttonStyle(PillButtonStyle(primary: true)).disabled(!model.canSpeak)
            }
            if model.lastAudio != nil && !model.isBusy { miniPlayer }
            NavigationLink { VoiceView() } label: { Text("声を追加・管理する") }.buttonStyle(PillButtonStyle())
        }
        .fileImporter(isPresented: $importingText, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { model.importTextFile(url) }
        }
    }

    private var voiceChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("話す声（タップで切り替え）").font(.system(size: 13)).foregroundColor(Palette.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.voices, id: \.id) { voice in
                        let active = voice.id == model.activeVoiceId
                        Button { model.switchVoice(voice.id) } label: {
                            Text(voice.name).font(.system(size: 15, weight: .medium))
                                .foregroundColor(active ? .white : Palette.ink)
                                .padding(.horizontal, 18).frame(minHeight: 44)
                                .background(Capsule().fill(active ? Palette.primary : Palette.secondary))
                        }
                        .accessibilityLabel(voice.name + (active ? "、選択中" : ""))
                    }
                }
            }
        }
    }

    private var miniPlayer: some View {
        MiniPlayerView(player: model.player, title: model.lastAudioTitle) { showPlayer = true; model.player.play() }
    }
}

/// The compact player under the read button; tapping it opens the full-screen player and starts playing.
struct MiniPlayerView: View {
    @ObservedObject var player: PlaybackController
    let title: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Palette.primary)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").foregroundColor(.white)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("できた音声を聞く").font(.system(size: 16, weight: .medium)).foregroundColor(Palette.ink)
                    Text(title).font(.system(size: 13)).foregroundColor(Palette.muted).lineLimit(1)
                }
                Spacer()
                Text(clock(player.duration)).font(.system(size: 13)).foregroundColor(Palette.muted)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.input))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.border, lineWidth: 1))
        }
    }
}
