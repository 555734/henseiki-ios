import SwiftUI
import UniformTypeIdentifiers
import VoiceCloneCore

/// Register voices by recording (free talk or six sample lines) or from an audio file, and manage the registered voices.
struct VoiceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var importingAudio = false
    @State private var renaming: VoiceLibrary.Entry?
    @State private var newName = ""
    @State private var deleting: VoiceLibrary.Entry?
    @State private var askConsent = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !model.voices.isEmpty { voiceList }
                fileCard
                recordCard
                if model.clipCount > 0 { registerCard }
                if !model.status.isEmpty { Text(model.status).font(.system(size: 13)).foregroundColor(Palette.muted).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .padding(20)
        }
        .background(Color.white.ignoresSafeArea())
        .navigationTitle("声の登録")
        .navigationBarTitleDisplayMode(.inline)
        .alert("自分の声を使いますか？", isPresented: $askConsent) {
            Button("はい、使います") { model.giveVoiceConsent() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("登録できるのは、ご自身の声、または持ち主から許可を得た声だけです。録音・声のデータはこの端末の中だけに保存されます。")
        }
        .alert("声の名前", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名前", text: $newName)
            Button("変更") { if let entry = renaming { model.renameVoice(entry.id, to: newName) }; renaming = nil }
            Button("キャンセル", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("この声を削除しますか？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("削除する", role: .destructive) { if let entry = deleting { model.deleteVoice(entry.id) }; deleting = nil }
            Button("キャンセル", role: .cancel) { deleting = nil }
        } message: { Text("この声の特徴データだけを削除します。録音とモデルは残ります。") }
        .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { model.importAudioFile(url) }
        }
    }

    private var voiceList: some View {
        Card {
            Text("登録した声").font(.system(size: 17, weight: .medium)).foregroundColor(Palette.ink)
            ForEach(model.voices, id: \.id) { voice in
                let active = voice.id == model.activeVoiceId
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(voice.name).font(.system(size: 16, weight: .medium)).foregroundColor(Palette.ink)
                        Spacer()
                        if active { Text("使用中").font(.system(size: 12)).foregroundColor(.white).padding(.horizontal, 10).padding(.vertical, 3).background(Capsule().fill(Palette.primary)) }
                    }
                    Text(detail(voice)).font(.system(size: 13)).foregroundColor(Palette.muted)
                    HStack(spacing: 8) {
                        if !active { Button("使う") { model.switchVoice(voice.id) }.buttonStyle(PillButtonStyle()) }
                        Button("名前変更") { newName = voice.name; renaming = voice }.buttonStyle(PillButtonStyle())
                        Button("削除") { deleting = voice }.buttonStyle(PillButtonStyle())
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func detail(_ voice: VoiceLibrary.Entry) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ja_JP"); formatter.dateFormat = "yyyy/MM/dd HH:mm"
        let date = voice.createdAt > 0 ? formatter.string(from: Date(timeIntervalSince1970: voice.createdAt)) + " · " : ""
        let seconds = voice.refSeconds > 0 ? String(format: " · 参照 %.0f 秒", voice.refSeconds) : ""
        return date + (voice.source == "imported" ? "取り込み" : "録音") + seconds
    }

    private var fileCard: some View {
        Card {
            Text("音声ファイルを使う").font(.system(size: 17, weight: .medium)).foregroundColor(Palette.ink)
            Text("WAV・MP3・M4Aなど（先頭120秒まで）").font(.system(size: 14)).foregroundColor(Palette.muted)
            Button("音声ファイルを選ぶ") { if model.voiceConsent { importingAudio = true } else { askConsent = true } }
                .buttonStyle(PillButtonStyle(primary: true)).disabled(!model.modelReady || model.isBusy)
        }
    }

    private var recordCard: some View { RecordCard(recorder: model.recorder, promptText: promptText, askConsent: $askConsent) }

    private var promptText: String {
        if model.freeTalk { return "好きなことを話してください。\n30秒ほどで十分です。\n\n例：今日あったこと／好きな食べ物／週末の予定" }
        if model.promptIndex < RecordingPrompts.registration { return "\(model.promptIndex + 1) / \(RecordingPrompts.registration) 文\n\n\(RecordingPrompts.lines[model.promptIndex])" }
        if let next = model.nextPrompt { return "\(RecordingPrompts.registration)文を録音しました。登録できます。\n\n\(next)" }
        return "提示文はすべて録音済みです。"
    }

    private var registerCard: some View {
        Card {
            Text("この音声で声を登録").font(.system(size: 17, weight: .medium)).foregroundColor(Palette.ink)
            Text(String(format: "録音 %.1f 秒 / おすすめ30秒", model.clipSeconds) + (model.clipSeconds < 3 ? "\n3秒たまると登録できます。" : "\n3秒から登録できます。長いほど似かたが安定します。"))
                .font(.system(size: 14)).foregroundColor(Palette.ink)
            ProgressView(value: min(1, model.clipSeconds / 30)).tint(Palette.primary)
            Button { model.register() } label: { Text(model.voiceReady ? "この音声で新しい声を登録する" : "この音声で声を登録する") }
                .buttonStyle(PillButtonStyle(primary: true)).disabled(!model.canRegister)
            Button("最後の音声を取り消す") { model.undoLastClip() }.buttonStyle(PillButtonStyle()).disabled(model.isBusy || model.isRecording)
        }
    }
}

/// The recording card; it watches the recorder so the timer and level meter update while recording.
struct RecordCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var recorder: MicRecorder
    let promptText: String
    @Binding var askConsent: Bool

    var body: some View {
        Card {
            Text("マイクで録音する").font(.system(size: 17, weight: .medium)).foregroundColor(Palette.ink)
            Picker("録音のしかた", selection: $model.freeTalk) {
                Text("自由に話す").tag(true)
                Text("文を読む").tag(false)
            }
            .pickerStyle(.segmented)
            .disabled(model.isRecording)
            Text(promptText).font(.system(size: 19)).foregroundColor(Palette.ink)
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.input))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.border, lineWidth: 1))
            if model.isRecording { ProgressView(value: Double(recorder.level)).tint(Palette.primary) }
            Button {
                if model.voiceConsent { model.toggleRecording() } else { askConsent = true }
            } label: { Text(model.isRecording ? String(format: "録音を止めて保存（%.1f秒）", recorder.seconds) : "録音を始める") }
                .buttonStyle(PillButtonStyle(primary: true)).disabled(model.isBusy)
        }
    }
}
