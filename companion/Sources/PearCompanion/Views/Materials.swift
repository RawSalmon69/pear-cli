import SwiftUI
import AppKit

extension NSView {
    /// Clip a borderless panel's hosting view to its card corner radius so the
    /// rectangular backing never shows a hairline past the rounded glass.
    /// Defaults to the same radius as `glassCard`.
    func clipToCard(radius: CGFloat = Theme.Radius.large) {
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
    }
}

/// The single material abstraction for the whole app. Liquid Glass on
/// macOS 26+, ultra-thin material below. Views use `.glassCard()` and
/// never touch materials directly, so the fallback stays in one place.
struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat = Theme.Radius.large

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

/// Wraps sibling `.glassCard()`s so Liquid Glass renders them as one group
/// (`GlassEffectContainer`, macOS 26+). Below 26 it passes the content
/// through and each card keeps its own material. Wrap siblings only — never
/// put glass inside glass.
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = Theme.Radius.large) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius))
    }
}
