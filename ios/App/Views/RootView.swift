import SwiftUI
import VoiceCloneCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showSettings = false
    @State private var showPlayer = false

    var body: some View {
        NavigationStack {
            HomeView(showPlayer: $showPlayer)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { Wordmark() }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showSettings = true } label: { Text("設定").foregroundColor(Palette.ink) }
                    }
                }
        }
        .tint(Palette.primary)
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() }.tint(Palette.primary) }
        .fullScreenCover(isPresented: $showPlayer) { PlayerView().tint(Palette.primary) }
        .fullScreenCover(isPresented: Binding(get: { !model.termsAccepted }, set: { _ in })) { TermsGateView() }
    }
}

struct Wordmark: View {
    var body: some View {
        (Text("Voice").foregroundColor(Palette.ink) + Text("Clone").foregroundColor(Palette.primary))
            .font(.system(size: 22, weight: .bold))
    }
}

/// First launch: the user must agree to the terms and the privacy policy before using the app.
struct TermsGateView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showDocuments = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 20)
            MarkView(size: 96)
            Text("ご利用にあたって").font(.system(size: 24, weight: .bold)).foregroundColor(Palette.ink)
            ScrollView { Text(LegalTexts.summary).font(.system(size: 16)).foregroundColor(Palette.ink).frame(maxWidth: .infinity, alignment: .leading) }
            Button("規約・ポリシーを読む") { showDocuments = true }.buttonStyle(PillButtonStyle())
            Button("同意して始める") { model.acceptTerms() }.buttonStyle(PillButtonStyle(primary: true))
            Text("同意いただけない場合は、このアプリを使うことができません。").font(.system(size: 12)).foregroundColor(Palette.muted)
        }
        .padding(24)
        .background(Color.white.ignoresSafeArea())
        .sheet(isPresented: $showDocuments) {
            NavigationStack { DocumentView(title: "利用規約・プライバシーポリシー", text: LegalTexts.terms + "\n\n――――――――――\n\n" + LegalTexts.privacy) }
        }
    }
}

struct DocumentView: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView { Text(text).font(.system(size: 15)).foregroundColor(Palette.ink).padding(24).frame(maxWidth: .infinity, alignment: .leading) }
            .background(Color.white)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("閉じる") { dismiss() } } }
    }
}
