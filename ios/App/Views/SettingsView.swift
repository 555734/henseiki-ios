import SwiftUI
import VoiceCloneCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDeleteData = false
    @State private var confirmDeleteModel = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card {
                    Text("モデル").font(.system(size: 16, weight: .medium)).foregroundColor(Palette.ink)
                    Text(model.modelReady ? "標準・軽量：準備済み。ダウンロードは二度と必要ありません。" : "モデルはまだ準備されていません。ホーム画面から始められます。")
                        .font(.system(size: 14)).foregroundColor(Palette.muted)
                }
                Card {
                    Text("規約・ライセンス").font(.system(size: 16, weight: .medium)).foregroundColor(Palette.ink)
                    NavigationLink { DocumentView(title: "利用規約", text: LegalTexts.terms) } label: { Text("利用規約") }.buttonStyle(PillButtonStyle())
                    NavigationLink { DocumentView(title: "プライバシーポリシー", text: LegalTexts.privacy) } label: { Text("プライバシーポリシー") }.buttonStyle(PillButtonStyle())
                    NavigationLink { DocumentView(title: "ライセンス・出典", text: Self.licenseText()) } label: { Text("ライセンス・出典") }.buttonStyle(PillButtonStyle())
                    Text("VoiceClone \(Self.version)").font(.system(size: 13)).foregroundColor(Palette.muted)
                    if !AppPaths.contact.isEmpty { Text("お問い合わせ：\(AppPaths.contact)").font(.system(size: 13)).foregroundColor(Palette.muted) }
                }
                Card {
                    Text("データの管理").font(.system(size: 16, weight: .medium)).foregroundColor(Palette.ink)
                    Button("録音・声・生成音声をすべて削除") { confirmDeleteData = true }.buttonStyle(PillButtonStyle()).disabled(model.isBusy)
                    Button("モデルを削除") { confirmDeleteModel = true }.buttonStyle(PillButtonStyle()).disabled(model.isBusy || !model.modelReady)
                }
            }
            .padding(20)
        }
        .background(Color.white.ignoresSafeArea())
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("閉じる") { dismiss() } } }
        .confirmationDialog("録音・声・生成音声をすべて削除しますか？", isPresented: $confirmDeleteData, titleVisibility: .visible) {
            Button("すべて削除", role: .destructive) { model.deleteAllData() }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("録音、登録した声、生成した音声、入力途中の文章を削除します。ダウンロード済みのモデルと、保存したファイルは消えません。") }
        .confirmationDialog("モデルを削除しますか？", isPresented: $confirmDeleteModel, titleVisibility: .visible) {
            Button("削除", role: .destructive) { model.deleteModel() }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("もう一度使うには、約1.1 GBのダウンロードが必要です。登録した声は残ります。") }
    }

    private static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    /// The same attribution file the Android app shows.
    private static func licenseText() -> String {
        guard let url = Bundle.main.url(forResource: "model-attribution", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let licenses = root["licenses"] as? [[String: Any]] else { return "ライセンス情報を読み込めませんでした。" }
        let entries = licenses.map { ($0["name"] as? String ?? "") + "\n" + ($0["text"] as? String ?? "") }
        let notices = ((root["third_party_notices"] as? [String: Any])?["text"] as? String) ?? ""
        return (entries + [notices]).joined(separator: "\n\n")
    }
}
