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

    @State private var zoom = ZoomController()
    @State private var picked: PickedColor?
    @State private var copiedValue: String?
    @State private var copiedResetToken = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ZoomableImage(image: image, controller: zoom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottomLeading) { zoomBar }
                Divider()
                sidebar
                    .frame(width: ScreenshotDetailLayout.sidebarWidth)
            }
            Divider()
            actionBar
        }
        .frame(minWidth: ScreenshotDetailLayout.minimum.width,
               minHeight: ScreenshotDetailLayout.minimum.height)
        .onAppear {
            zoom.onPick = { color in
                picked = color
                copy(color)
            }
        }
    }

    /// Zoom chrome over the image's bottom-left: out / readout / in, then fit
    /// and 1:1. ⌘−, ⌘+ and ⌘0 do the same from the keyboard.
    private var zoomBar: some View {
        HStack(spacing: 2) {
            ZoomButton(symbol: "minus.magnifyingglass", help: "Zoom out", action: zoom.zoomOut)
                .keyboardShortcut("-", modifiers: .command)
            Text("\(zoom.percent)%")
                .font(Theme.caption)
                .monospacedDigit()
                .frame(width: 46)
            ZoomButton(symbol: "plus.magnifyingglass", help: "Zoom in", action: zoom.zoomIn)
                .keyboardShortcut("+", modifiers: .command)
            Divider().frame(height: 14)
            ZoomButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Fit", action: zoom.fit)
                .keyboardShortcut("0", modifiers: .command)
            ZoomButton(symbol: "1.magnifyingglass", help: "Actual size", action: zoom.actualSize)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .padding(12)
    }

    /// Copies a color in the user's chosen format and flashes a confirmation —
    /// the palette used to copy silently, which reads as "nothing happened".
    private func copy(_ color: PickedColor) {
        let value = Prefs.colorFormat.value(for: color)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        SoundEffects.play(.copy)
        withAnimation(.easeOut(duration: 0.12)) { copiedValue = value }
        copiedResetToken += 1
        let token = copiedResetToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard token == copiedResetToken else { return }
            withAnimation(.easeOut(duration: 0.2)) { copiedValue = nil }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionGap) {
                // Text always has a section, even mid-scan or empty, so the
                // window is readable the instant it opens and the reader can
                // see that recognition is still running rather than missing.
                textSection
                if !insights.payloads.isEmpty { qrSection }
                colorSection
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

    /// Palette plus the eyedropper's pick. Clicking any swatch copies it in the
    /// user's chosen format and says so.
    private var colorSection: some View {
        DetailSection(
            title: "Colors",
            subtitle: copiedValue.map { "\($0) copied" } ?? (zoom.isPicking ? "click the shot" : nil),
            action: DetailSection.Action(
                symbol: zoom.isPicking ? "eyedropper.halffull" : "eyedropper",
                help: zoom.isPicking ? "Stop picking" : "Pick a color from the shot",
                run: { zoom.isPicking.toggle() }
            )
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if let picked {
                    HStack(spacing: 8) {
                        Swatch(color: picked, size: CGSize(width: 44, height: 26),
                               copied: copiedValue == Prefs.colorFormat.value(for: picked)) {
                            copy(picked)
                        }
                        Text(Prefs.colorFormat.value(for: picked))
                            .font(Theme.body)
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }
                }
                if insights.colors.isEmpty {
                    if insights.isScanning {
                        Text("Reading colors…").font(Theme.body).foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 6) {
                        ForEach(insights.colors) { swatch in
                            Swatch(color: swatch, size: CGSize(width: 30, height: 24),
                                   copied: copiedValue == Prefs.colorFormat.value(for: swatch)) {
                                copy(swatch)
                            }
                        }
                    }
                }
            }
        }
    }

    private var detailSection: some View {
        let details = insights.details
        return DetailSection(title: "Details") {
            VStack(alignment: .leading, spacing: 4) {
                DetailRow(label: "Dimensions", value: details.dimensionsLabel)
                if let megapixels = details.megapixelsLabel {
                    DetailRow(label: "Pixels", value: megapixels)
                }
                if let aspect = details.aspectLabel {
                    DetailRow(label: "Aspect", value: aspect)
                }
                DetailRow(label: "File", value: "\(details.format) · \(details.sizeLabel)")
                if let color = details.colorLabel {
                    DetailRow(label: "Color", value: color)
                }
                if details.dpi > 0 {
                    DetailRow(
                        label: "Resolution",
                        value: [String(details.dpi) + " dpi", details.scaleLabel]
                            .compactMap { $0 }.joined(separator: " · "))
                }
                DetailRow(label: "Alpha", value: details.hasAlpha ? "Yes" : "No")
                DetailRow(label: "Taken", value: details.timeLabel)
                if let name = details.fileName {
                    DetailRow(label: "Name", value: name)
                }
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

/// Bridge between the SwiftUI chrome (zoom buttons, ⌘+/⌘−/⌘0, the eyedropper
/// toggle) and the AppKit scroll view that does the actual zooming.
@MainActor
@Observable
final class ZoomController {
    /// Current magnification as a percentage of actual size, for the readout.
    private(set) var percent: Int = 100
    /// While true, a click samples the pixel under the cursor instead of doing
    /// nothing, and the cursor becomes a crosshair.
    var isPicking = false {
        didSet { scrollView?.refreshCursor(picking: isPicking) }
    }
    /// Called with the sampled color when the eyedropper is used.
    @ObservationIgnored var onPick: ((PickedColor) -> Void)?

    @ObservationIgnored weak var scrollView: ZoomableImageScrollView?

    func zoomIn() { scrollView?.step(by: 1.4) }
    func zoomOut() { scrollView?.step(by: 1 / 1.4) }
    func fit() { scrollView?.fitToWindow(animated: true) }
    func actualSize() { scrollView?.setMagnification(1, animated: true) }

    fileprivate func report(_ magnification: CGFloat) {
        percent = max(1, Int((magnification * 100).rounded()))
    }
}

/// The shot, zoomable the way macOS zooms: an `NSScrollView` with magnification
/// on, which is what Preview and Quick Look use. Pinch, ⌘-scroll and two-finger
/// pan all come from AppKit; double-click toggles fit ↔ 100%. No custom gesture
/// math — the system path already handles trackpad, mouse and accessibility.
struct ZoomableImage: NSViewRepresentable {
    let image: NSImage
    let controller: ZoomController

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

        // Centering clip view: without it a fitted shot sits in the bottom-left
        // corner of the viewport instead of the middle, which is most of what
        // made zooming feel wrong.
        let clipView = CenteringClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = imageView
        scrollView.allowsMagnification = true
        scrollView.maxMagnification = 16
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // Free two-axis panning; the default snaps to whichever axis you
        // started on, which fights a diagonal drag around a zoomed shot.
        scrollView.usesPredominantAxisScrolling = false
        scrollView.sourceImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        scrollView.controller = controller
        controller.scrollView = scrollView

        let doubleClick = NSClickGestureRecognizer(
            target: scrollView, action: #selector(ZoomableImageScrollView.handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        scrollView.addGestureRecognizer(doubleClick)

        let click = NSClickGestureRecognizer(
            target: scrollView, action: #selector(ZoomableImageScrollView.handleClick(_:)))
        click.numberOfClicksRequired = 1
        scrollView.addGestureRecognizer(click)
        return scrollView
    }

    func updateNSView(_ scrollView: ZoomableImageScrollView, context: Context) {
        guard let imageView = scrollView.documentView as? NSImageView,
              imageView.image !== image else { return }
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: pixelSize)
        scrollView.sourceImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        scrollView.resetFit()
    }
}

/// Keeps the document centered when it's smaller than the viewport.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let document = documentView.frame
        if rect.width > document.width {
            rect.origin.x = (document.width - rect.width) / 2
        }
        if rect.height > document.height {
            rect.origin.y = (document.height - rect.height) / 2
        }
        return rect
    }
}

/// Owns fit state, the zoom steps, and the eyedropper hit-test.
final class ZoomableImageScrollView: NSScrollView {
    weak var controller: ZoomController?
    var sourceImage: CGImage?

    private var didFit = false
    private var fitMagnification: CGFloat = 1
    /// Once the user zooms deliberately, a window resize must not yank them
    /// back to fit.
    private var userAdjusted = false

    override func layout() {
        super.layout()
        guard bounds.width > 1, documentView != nil else { return }
        guard !didFit || !userAdjusted else { return }
        didFit = true
        // Deferred: never change scroll geometry inside the layout pass that
        // asked for it (the re-entrant-constraint rule this app learned the
        // hard way with its panels).
        DispatchQueue.main.async { [weak self] in self?.fitToWindow(animated: false) }
    }

    /// Re-fit for a new image.
    func resetFit() {
        didFit = false
        userAdjusted = false
        needsLayout = true
    }

    func fitToWindow(animated: Bool) {
        guard let document = documentView, document.bounds.width > 0 else { return }
        let target = min(
            bounds.width / document.bounds.width,
            bounds.height / document.bounds.height
        )
        guard target.isFinite, target > 0 else { return }
        fitMagnification = target
        // Never zoom out past fit: an image floating in a sea of empty window
        // is nobody's idea of zoomed out.
        minMagnification = min(target, 1)
        userAdjusted = false
        setMagnification(target, animated: animated)
    }

    func step(by factor: CGFloat) {
        setMagnification(magnification * factor, animated: true)
        userAdjusted = true
    }

    func setMagnification(_ value: CGFloat, animated: Bool) {
        let clamped = min(max(value, minMagnification), maxMagnification)
        guard abs(clamped - magnification) > 0.001 else {
            controller?.report(magnification)
            return
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().magnification = clamped
            }
        } else {
            magnification = clamped
        }
        controller?.report(clamped)
    }

    func refreshCursor(picking: Bool) {
        window?.invalidateCursorRects(for: self)
        if picking { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if controller?.isPicking == true {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    /// Pinch and ⌘-scroll are AppKit's; this just keeps the readout honest and
    /// remembers that the user took control.
    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        userAdjusted = true
        controller?.report(magnification)
    }

    @objc func handleDoubleClick(_ sender: NSClickGestureRecognizer) {
        guard controller?.isPicking != true, let document = documentView else { return }
        if magnification > fitMagnification * 1.05 {
            fitToWindow(animated: true)
        } else {
            let point = document.convert(sender.location(in: self), from: self)
            userAdjusted = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setMagnification(1, centeredAt: point)
            }
            controller?.report(1)
        }
    }

    @objc func handleClick(_ sender: NSClickGestureRecognizer) {
        guard controller?.isPicking == true,
              let document = documentView,
              let image = sourceImage else { return }
        let point = document.convert(sender.location(in: self), from: self)
        let scaleX = CGFloat(image.width) / document.bounds.width
        let scaleY = CGFloat(image.height) / document.bounds.height
        // Document coordinates run bottom-up; CGImage rows run top-down.
        let x = Int((point.x * scaleX).rounded(.down))
        let y = Int(((document.bounds.height - point.y) * scaleY).rounded(.down))
        guard let color = PixelSampler.color(in: image, atX: x, y: y) else { return }
        controller?.onPick?(color)
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
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Theme.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(Theme.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// A color chip that copies on click and says so — a checkmark in whichever of
/// black or white actually contrasts with the swatch (WCAG luminance, the same
/// math the color picker tool uses).
private struct Swatch: View {
    let color: PickedColor
    let size: CGSize
    let copied: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.swiftUIColor)
                .frame(width: size.width, height: size.height)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.white.opacity(hovering ? 0.7 : 0.18),
                                      lineWidth: hovering ? 1 : 0.5)
                }
                .overlay {
                    if copied {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(color.luminance > 0.4 ? .black : .white)
                    }
                }
                .scaleEffect(hovering ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Copy \(color.hexString)")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: copied)
    }
}

/// Icon-only control for the zoom capsule.
private struct ZoomButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Theme.accent : .primary)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .onHover { hovering = $0 }
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
