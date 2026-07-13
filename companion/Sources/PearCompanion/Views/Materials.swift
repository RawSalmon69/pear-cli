import SwiftUI

/// The single material abstraction for the whole app. Liquid Glass on
/// macOS 26+, ultra-thin material below. Views use `.glassCard()` and
/// never touch materials directly, so the fallback stays in one place.
struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 14) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius))
    }
}
