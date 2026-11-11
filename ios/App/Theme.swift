import SwiftUI

/// White canvas, hairline borders, orange primary buttons (same look as the Android app).
enum Palette {
    static let primary = Color(red: 0.918, green: 0.345, blue: 0.047)    // #EA580C
    static let accent = Color(red: 0.761, green: 0.255, blue: 0.047)     // #C2410C
    static let ink = Color(red: 0.165, green: 0.102, blue: 0.063)        // #2A1A10
    static let muted = Color(red: 0.478, green: 0.404, blue: 0.353)      // #7A675A
    static let pale = Color(red: 1.0, green: 0.922, blue: 0.851)         // #FFEBD9
    static let secondary = Color(red: 1.0, green: 0.937, blue: 0.878)    // #FFEFE0
    static let border = Color(red: 0.945, green: 0.875, blue: 0.816)     // #F1DFD0
    static let input = Color(red: 1.0, green: 0.961, blue: 0.925)        // #FFF5EC
}

struct PillButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(primary ? .white : Palette.ink)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 14).fill(primary ? Palette.primary : Palette.secondary))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.border, lineWidth: 1))
    }
}

/// The app mark: a ring around a small sound wave.
struct MarkView: View {
    var size: CGFloat
    private let heights: [CGFloat] = [0.20, 0.34, 0.50, 0.30, 0.18]
    var body: some View {
        ZStack {
            Circle().stroke(Palette.primary, lineWidth: size * 0.04)
            HStack(spacing: size * 0.06) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule().fill(Palette.primary).frame(width: size * 0.065, height: size * heights[index])
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

func clock(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds))
    return String(format: "%d:%02d", total / 60, total % 60)
}
