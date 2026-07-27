import SwiftUI
import AppKit

/// Pure sizing math for the detail window, so the clamp is testable without a
/// screen: fit the image's aspect inside a share of the visible frame, add the
/// sidebar, then hold a floor so a tiny capture still gets a usable window.
enum ScreenshotDetailLayout {
    static let sidebarWidth: CGFloat = 260
    static let actionBarHeight: CGFloat = 44
    static let minimum = NSSize(width: 720, height: 480)
    /// Share of the visible frame the image area may claim.
    static let fill: CGFloat = 0.7

    static func windowSize(image: NSSize, visible: NSRect,
                           sidebar: CGFloat = sidebarWidth,
                           minimum: NSSize = minimum) -> NSSize {
        guard image.width > 0, image.height > 0, visible.width > 0, visible.height > 0 else {
            return minimum
        }
        let maxImage = NSSize(width: visible.width * fill - sidebar,
                             height: visible.height * fill - actionBarHeight)
        // Never upscale past the capture's own pixels; never overflow the screen.
        let scale = min(1, min(maxImage.width / image.width, maxImage.height / image.height))
        let fitted = NSSize(width: image.width * scale, height: image.height * scale)
        return NSSize(
            width: max(minimum.width, fitted.width + sidebar),
            height: max(minimum.height, fitted.height + actionBarHeight)
        )
    }
}

/// The big view of a capture: the shot at a readable size, its insights
/// alongside, and the same actions the preview card offers. One window per
/// card — the controller is held by the preview controller, which reuses it
/// when the same card is clicked again.
@MainActor
final class ScreenshotDetailWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let content: ScreenshotDetailView
    private let imageSize: NSSize
    var onClosed: (() -> Void)?

    init(content: ScreenshotDetailView, imageSize: NSSize) {
        self.content = content
        self.imageSize = imageSize
    }

    /// Shows the window, or brings an already-open one forward.
    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let visible = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? .zero
        let size = ScreenshotDetailLayout.windowSize(image: imageSize, visible: visible)
        let window = DetailWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.title = "Screenshot"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onClosed?()
    }
}

/// Esc closes, matching the Disk / Monitor / Scratchpad windows.
private final class DetailWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}

/// Image left, insights right, actions along the bottom. Every action is a
/// closure handed down from the preview card, so there is one implementation of
/// copy / save / reveal / send in the app.
struct ScreenshotDetailView: View {
    let image: NSImage
    let insights: ScreenshotInsights
    let canMarkup: Bool
    let canSend: Bool
    let canSave: Bool
    let canRemoveBackground: Bool
    let onCopy: () -> Void
    let onCopyText: (() -> Void)?
    let onQRTap: (([String]) -> Void)?
    let onSave: () -> Void
    let onReveal: () -> Void
    let onMarkup: () -> Void
    let onRemoveBackground: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ZoomableImage(image: image)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                sidebar
                    .frame(width: ScreenshotDetailLayout.sidebarWidth)
            }
            Divider()
            actionBar
        }
        .frame(minWidth: ScreenshotDetailLayout.minimum.width,
               minHeight: ScreenshotDetailLayout.minimum.height)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionGap) {
                // Text always has a section, even mid-scan or empty, so the
                // window is readable the instant it opens and the reader can
                // see that recognition is still running rather than missing.
                textSection
                if !insights.payloads.isEmpty { qrSection }
                if !insights.colors.isEmpty { colorSection }
                detailSection
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Recognized text in its own bordered, independently scrolling box — the
    /// whole thing, never truncated, with a line count so it reads as a
    /// transcript of the shot rather than a caption on it.
    private var textSection: some View {
        DetailSection(
            title: "Extracted text",
            subtitle: textSubtitle,
            action: insights.text.isEmpty ? nil : onCopyText.map { copy in
                DetailSection.Action(symbol: "doc.on.doc", help: "Copy all text", run: copy)
            }
        ) {
            if !insights.text.isEmpty {
                ScrollView {
                    Text(insights.text)
                        .font(Theme.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 190)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                }
            } else if insights.isScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading text…").font(Theme.body).foregroundStyle(.secondary)
                }
            } else {
                Text("No text found").font(Theme.body).foregroundStyle(.secondary)
            }
        }
    }

    private var textSubtitle: String? {
        guard !insights.text.isEmpty else { return nil }
        let lines = insights.text.split(separator: "\n").count
        return lines == 1 ? "1 line" : "\(lines) lines"
    }

    private var qrSection: some View {
        DetailSection(title: insights.payloads.count > 1 ? "QR codes" : "QR code",
                      action: DetailSection.Action(symbol: "doc.on.doc", help: "Copy code") {
                          onQRTap?(insights.payloads)
                      }) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(insights.payloads, id: \.self) { payload in
                    if let url = QRCode.openableURL(in: [payload]) {
                        Link(payload, destination: url)
                            .font(Theme.body)
                            .lineLimit(2)
                    } else {
                        Text(payload)
                            .font(Theme.body)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                }
            }
        }
    }

    private var colorSection: some View {
        DetailSection(title: "Colors") {
            HStack(spacing: 6) {
                ForEach(insights.colors, id: \.self) { swatch in
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(swatch.hex, forType: .string)
                        SoundEffects.play(.copy)
                    } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(swatch.color)
                            .frame(width: 30, height: 24)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                            }
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("Copy \(swatch.hex)")
                }
            }
        }
    }

    private var detailSection: some View {
        DetailSection(title: "Details") {
            VStack(alignment: .leading, spacing: 4) {
                DetailRow(label: "Size", value: insights.details.dimensionsLabel)
                DetailRow(label: "File", value: "\(insights.details.format) · \(insights.details.sizeLabel)")
                DetailRow(label: "Taken", value: insights.details.timeLabel)
                if let path = insights.details.path {
                    Button(action: onReveal) {
                        Text(path)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.accent)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("Reveal in Finder")
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            DetailAction(symbol: "doc.on.doc", title: "Copy", action: onCopy)
                .keyboardShortcut("c", modifiers: .command)
            if canSave {
                DetailAction(symbol: "square.and.arrow.down", title: "Save", action: onSave)
                    .keyboardShortcut("s", modifiers: .command)
            }
            DetailAction(symbol: "folder", title: "Reveal", action: onReveal)
            if canRemoveBackground {
                DetailAction(symbol: "person.and.background.dotted",
                             title: "Remove background", action: onRemoveBackground)
            }
            if canMarkup {
                DetailAction(symbol: "pencil.tip.crop.circle", title: "Markup", action: onMarkup)
            }
            Spacer()
            if canSend {
                DetailAction(symbol: "paperplane.fill", title: "Send",
                             tint: Theme.accent, action: onSend)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: ScreenshotDetailLayout.actionBarHeight)
    }
}

/// The shot, zoomable the way macOS zooms: an `NSScrollView` with magnification
/// on, which is what Preview and Quick Look use. Pinch, ⌘-scroll, and two-finger
/// pan all come from AppKit; double-click toggles fit ↔ 100%. No custom gesture
/// math — the system path already handles trackpad, mouse, and accessibility.
struct ZoomableImage: NSViewRepresentable {
    let image: NSImage

    /// True pixels where the bitmap knows them; a Retina PNG reports half-size
    /// `NSImage.size`, and zooming should reach the real resolution.
    private var pixelSize: NSSize {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    func makeNSView(context: Context) -> ZoomableImageScrollView {
        let scrollView = ZoomableImageScrollView()
        let imageView = NSImageView()
        imageView.imageScaling = .scaleAxesIndependently
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: pixelSize)

        scrollView.documentView = imageView
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 8
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false

        let doubleClick = NSClickGestureRecognizer(
            target: scrollView, action: #selector(ZoomableImageScrollView.toggleZoom(_:)))
        doubleClick.numberOfClicksRequired = 2
        scrollView.addGestureRecognizer(doubleClick)
        return scrollView
    }

    func updateNSView(_ scrollView: ZoomableImageScrollView, context: Context) {
        guard let imageView = scrollView.documentView as? NSImageView else { return }
        guard imageView.image !== image else { return }
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: pixelSize)
        scrollView.resetFit()
    }
}

/// Holds the fit magnification so double-click can toggle against it, and does
/// the initial fit once the view actually has a size.
final class ZoomableImageScrollView: NSScrollView {
    private var didFit = false
    private var fitMagnification: CGFloat = 1

    override func layout() {
        super.layout()
        guard !didFit, bounds.width > 1, documentView != nil else { return }
        didFit = true
        // Deferred: never change scroll geometry inside the layout pass that
        // asked for it (the re-entrant-constraint rule this app learned the
        // hard way with panels).
        DispatchQueue.main.async { [weak self] in self?.fit() }
    }

    /// Re-fit for a new image.
    func resetFit() {
        didFit = false
        needsLayout = true
    }

    private func fit() {
        guard let document = documentView else { return }
        magnify(toFit: document.bounds)
        fitMagnification = magnification
    }

    @objc func toggleZoom(_ sender: NSClickGestureRecognizer) {
        guard let document = documentView else { return }
        if magnification > fitMagnification * 1.05 {
            fit()
        } else {
            let point = document.convert(sender.location(in: self), from: self)
            setMagnification(1, centeredAt: point)
        }
    }
}

/// Sidebar section: a small caps-y heading, an optional copy button, content.
private struct DetailSection<Content: View>: View {
    struct Action {
        let symbol: String
        let help: String
        let run: () -> Void
    }

    let title: String
    var subtitle: String?
    var action: Action?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let action {
                    Button(action: action.run) {
                        Image(systemName: action.symbol).font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help(action.help)
                }
            }
            content()
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).font(Theme.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(Theme.body)
        }
    }
}

/// Labeled action-bar button — the detail view has room for words, unlike the
/// card's icon-only bar.
private struct DetailAction: View {
    let symbol: String
    let title: String
    var tint: Color = .primary
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                Text(title).font(Theme.body)
            }
            .foregroundStyle(hovering ? Theme.accent : tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.accentSoft : .clear))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(title)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
