import AppKit
import SwiftUI

/// A plain-text editor that auto-detects URLs and opens them on click, standing
/// in for `TextEditor` (which has no link detection on macOS 14). The binding
/// stays a plain `String` — we only ever read `textView.string` back out, so the
/// note model and its JSON are unchanged. Link attributes are display-only.
struct LinkTextView: NSViewRepresentable {
    @Binding var text: String
    /// Live from `ScratchpadSettings.linkDetection()`; off clears link marking
    /// on the next load.
    let detectLinks: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.allowsUndo = true
        // Rich text so data-detected URLs can carry link attributes for display
        // and click handling; storage stays plain because we persist `.string`.
        textView.isRichText = true
        textView.usesFontPanel = false
        textView.font = Self.editorFont
        // Match TextEditor's inset so the swap is visually invisible.
        textView.textContainerInset = NSSize(width: 0, height: 7)
        applyDetection(to: textView)
        textView.string = text
        if detectLinks { textView.checkTextInDocument(nil) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }

        applyDetection(to: textView)
        // Only push store text into the view when it actually differs, so a
        // fresh keystroke round-tripping through the binding can't reset the
        // string mid-edit (which would kill the cursor position). A differing
        // string means a note switch (or external change): reset and re-scan.
        if textView.string != text {
            textView.string = text
            textView.font = Self.editorFont
            if detectLinks { textView.checkTextInDocument(nil) }
        }
    }

    /// The 13pt rounded system font that matches `Theme.body`.
    private static let editorFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 13)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: 13) ?? base
    }()

    private func applyDetection(to textView: NSTextView) {
        textView.isAutomaticLinkDetectionEnabled = detectLinks
        textView.enabledTextCheckingTypes = detectLinks ? NSTextCheckingResult.CheckingType.link.rawValue : 0
    }

    /// Bridges the AppKit text view back to the SwiftUI binding and opens links.
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LinkTextView

        init(_ parent: LinkTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Always the plain string — formatting never reaches the store.
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL?
            switch link {
            case let value as URL: url = value
            case let value as String: url = URL(string: value)
            default: url = nil
            }
            guard let url else { return false }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}
