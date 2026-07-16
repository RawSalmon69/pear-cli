import SwiftUI
import AppKit

extension NSView {
    /// Clip a borderless panel's hosting view to its card corner radius so the
    /// rectangular backing never shows a hairline past the rounded glass.
    func clipToCard(radius: CGFloat = 16) {
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
    }
}

/// The single material abstraction for the whole app. Liquid Glass on
/// macOS 26+, ultra-thin material below. Views use `.glassCard()` and
/// never touch materials directly, so the fallback stays in one place.
struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // Clip the content to the same shape the glass uses; without it,
            // square content layers leak a hairline past the curved rim.
            content
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
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
