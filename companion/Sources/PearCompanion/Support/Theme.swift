import SwiftUI

/// Design tokens. Type scale is 3:4 (11 · 13 · 15 · 17 · 22); spacing is a
/// 4-based scale where section gaps (20) dominate intra-section gaps (8) so
/// whitespace, not rules, carries the hierarchy.
enum Theme {
    // Pear green: warm accent that advances against the cool glass.
    static let accent = Color(red: 0.48, green: 0.68, blue: 0.32)
    static let accentSoft = Color(red: 0.48, green: 0.68, blue: 0.32).opacity(0.16)
    static let warn = Color(red: 0.86, green: 0.62, blue: 0.22)

    static let sectionGap: CGFloat = 20
    static let itemGap: CGFloat = 8
    static let cardPadding: CGFloat = 12
    static let heroPadding: CGFloat = 14

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static let caption = rounded(11, .semibold)
    static let body = rounded(13)
    static let emphasis = rounded(15, .medium)
    static let title = rounded(17, .semibold)
    static let hero = rounded(22, .bold)
}

/// Section label: small caps feel without fighting the notes for attention.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Theme.caption)
            .kerning(0.8)
            .foregroundStyle(.secondary)
    }
}

/// Soft hover-reactive icon button used across the composer and cards.
struct GlyphButton: View {
    let symbol: String
    let help: String
    var tint: Color = .primary
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Theme.accent : tint)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(hovering ? Theme.accentSoft : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
