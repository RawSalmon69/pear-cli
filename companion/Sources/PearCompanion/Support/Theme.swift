import SwiftUI
import Observation

/// The user-selectable accent presets. Pear green is the identity default;
/// the rest are tuned to advance similarly against the glass.
enum AccentPreset: String, CaseIterable, Identifiable {
    case pear, blue, purple, orange, pink, teal, graphite

    var id: String { rawValue }

    var name: String {
        switch self {
        case .pear: return "Pear"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .orange: return "Orange"
        case .pink: return "Pink"
        case .teal: return "Teal"
        case .graphite: return "Graphite"
        }
    }

    var color: Color {
        switch self {
        case .pear: return Color(red: 0.48, green: 0.68, blue: 0.32)
        case .blue: return Color(red: 0.31, green: 0.56, blue: 0.94)
        case .purple: return Color(red: 0.62, green: 0.47, blue: 0.92)
        case .orange: return Color(red: 0.94, green: 0.58, blue: 0.27)
        case .pink: return Color(red: 0.93, green: 0.44, blue: 0.63)
        case .teal: return Color(red: 0.26, green: 0.70, blue: 0.68)
        case .graphite: return Color(red: 0.56, green: 0.58, blue: 0.62)
        }
    }
}

/// Holds the live accent choice. `@Observable`, so any view that reads
/// `Theme.accent` in its body re-renders the moment the user picks a new
/// preset — no relaunch.
@MainActor
@Observable
final class ThemeStore {
    static let shared = ThemeStore()
    private static let defaultsKey = "accentPreset"

    var preset: AccentPreset {
        didSet { UserDefaults.standard.set(preset.rawValue, forKey: Self.defaultsKey) }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        preset = stored.flatMap(AccentPreset.init(rawValue:)) ?? .pear
    }
}

/// Design tokens. Type scale is 3:4 (11 · 13 · 15 · 17 · 22); spacing is a
/// 4-based scale where section gaps (20) dominate intra-section gaps (8) so
/// whitespace, not rules, carries the hierarchy.
enum Theme {
    @MainActor static var accent: Color { ThemeStore.shared.preset.color }
    @MainActor static var accentSoft: Color { ThemeStore.shared.preset.color.opacity(0.16) }
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
        .focusable(false)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
