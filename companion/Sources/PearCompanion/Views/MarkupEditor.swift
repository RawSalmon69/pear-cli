import SwiftUI
import AppKit

// MARK: - Entry point

@MainActor
enum MarkupWindow {
    /// Live controllers keep themselves (and their NSWindow) alive until the
    /// user finishes; SwiftUI-hosted windows are otherwise deallocated.
    private static var controllers: [MarkupWindowController] = []

    /// Opens a modal-ish editor window for `image`. Calls onComplete with the
    /// flattened annotated image when the user hits Done, or nil if cancelled.
    static func present(image: NSImage, onComplete: @escaping (NSImage?) -> Void) {
        let controller = MarkupWindowController(image: image, onComplete: onComplete)
        controller.onClosed = { finished in
            controllers.removeAll { $0 === finished }
        }
        controllers.append(controller)
        controller.show()
    }
}

// MARK: - Window controller

@MainActor
final class MarkupWindowController: NSObject, NSWindowDelegate {
    private let image: NSImage
    private let onComplete: (NSImage?) -> Void
    var onClosed: ((MarkupWindowController) -> Void)?

    private var window: NSWindow?
    private var didComplete = false

    init(image: NSImage, onComplete: @escaping (NSImage?) -> Void) {
        self.image = image
        self.onComplete = onComplete
    }

    func show() {
        let root = MarkupEditorView(image: image) { [weak self] result in
            self?.finish(with: result)
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.initialContentSize(for: image)),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Markup"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 420)
        window.contentView = NSHostingView(rootView: root)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    /// Fit the image into ~80% of the main screen, leaving room for the toolbar.
    private static func initialContentSize(for image: NSImage) -> NSSize {
        let toolbarHeight: CGFloat = 64
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let maxCanvas = CGSize(
            width: screen.width * 0.8,
            height: screen.height * 0.8 - toolbarHeight
        )
        let px = image.pixelSize
        let scale = min(maxCanvas.width / px.width, maxCanvas.height / px.height, 1)
        let canvas = CGSize(width: px.width * scale, height: px.height * scale)
        return NSSize(width: max(canvas.width, 520), height: canvas.height + toolbarHeight)
    }

    private func finish(with result: NSImage?) {
        guard !didComplete else { return }
        didComplete = true
        onComplete(result)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing via the title-bar button (or any path we didn't drive) is a
        // cancel; guarded so Done doesn't double-report.
        if !didComplete {
            didComplete = true
            onComplete(nil)
        }
        window?.delegate = nil
        window = nil
        onClosed?(self)
    }
}

// MARK: - Editor view

struct MarkupEditorView: View {
    let image: NSImage
    let onFinish: (NSImage?) -> Void

    private let pixelSize: CGSize
    private let pixelated: NSImage?

    @State private var annotations: [Annotation] = []
    @State private var tool: MarkupTool = .arrow
    @State private var color: Color = Theme.accent
    @State private var strokeWidth: StrokeWidth = .medium

    /// In-progress drag in canvas (view) coordinates.
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    /// In-progress freehand stroke, in image coordinates (built up as the
    /// drag moves rather than derived from start/end like the other tools).
    @State private var freehandPoints: [CGPoint] = []

    /// Inline text entry. Origin and font size are stored in image space so
    /// they survive window resizes; the visible field is derived from the
    /// current scale.
    @State private var draftOrigin: CGPoint?
    @State private var draftText: String = ""
    @State private var draftFontSize: CGFloat = 0
    @FocusState private var textFieldFocused: Bool

    init(image: NSImage, onFinish: @escaping (NSImage?) -> Void) {
        self.image = image
        self.onFinish = onFinish
        self.pixelSize = image.pixelSize
        self.pixelated = Pixelation.pixelated(image)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.4)
            canvasArea
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: Theme.itemGap) {
            HStack(spacing: 2) {
                ForEach(MarkupTool.allCases) { candidate in
                    ToolButton(
                        symbol: candidate.symbol,
                        help: candidate.help,
                        isActive: tool == candidate
                    ) {
                        commitDraft()
                        tool = candidate
                    }
                }
            }
            .padding(4)
            .glassCard(cornerRadius: 10)

            Divider().frame(height: 22).opacity(0.4)

            ColorPicker("Colour", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .disabled(!tool.usesColor)
                .opacity(tool.usesColor ? 1 : 0.4)
                .help("Annotation colour")

            Picker("Stroke width", selection: $strokeWidth) {
                ForEach(StrokeWidth.allCases) { width in
                    Text(width.label).tag(width)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 108)
            .help("Stroke width")

            GlyphButton(symbol: "arrow.uturn.backward", help: "Undo") {
                undo()
            }
            .disabled(annotations.isEmpty)
            .keyboardShortcut("z", modifiers: .command)

            Spacer()

            Button("Cancel") { onFinish(nil) }
                .keyboardShortcut(.cancelAction)

            Button("Done") {
                commitDraft()
                onFinish(flatten())
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, Theme.itemGap)
        .font(Theme.body)
    }

    // MARK: Canvas

    private var canvasArea: some View {
        GeometryReader { geo in
            let scale = renderScale(in: geo.size)
            let displaySize = CGSize(
                width: pixelSize.width * scale,
                height: pixelSize.height * scale
            )

            ZStack(alignment: .topLeading) {
                MarkupCanvas(
                    base: image,
                    pixelated: pixelated,
                    annotations: annotations,
                    preview: previewAnnotation(scale: scale),
                    pixelSize: pixelSize,
                    renderScale: scale
                )

                if let draftOrigin {
                    TextField("Text", text: $draftText)
                        .textFieldStyle(.plain)
                        .font(.system(size: max(draftFontSize * scale, 6),
                                      weight: .semibold, design: .rounded))
                        .foregroundColor(color)
                        .focused($textFieldFocused)
                        .frame(minWidth: 40, alignment: .leading)
                        .fixedSize()
                        .padding(2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.thinMaterial))
                        .offset(x: draftOrigin.x * scale, y: draftOrigin.y * scale)
                        .onSubmit { commitDraft() }
                }
            }
            .frame(width: displaySize.width, height: displaySize.height)
            .contentShape(Rectangle())
            .gesture(canvasGesture(scale: scale))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(Theme.sectionGap)
    }

    // MARK: Layout math

    /// Uniform image→view scale that fits the image into the available area,
    /// never upscaling past native resolution.
    private func renderScale(in available: CGSize) -> CGFloat {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return 1 }
        let fit = min(available.width / pixelSize.width, available.height / pixelSize.height)
        return max(min(fit, 1), 0.01)
    }

    private func imagePoint(_ viewPoint: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: viewPoint.x / scale, y: viewPoint.y / scale)
    }

    // MARK: Interaction

    private func canvasGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard tool != .text else { return }
                dragStart = value.startLocation
                dragCurrent = value.location
                if tool == .freehand {
                    if freehandPoints.isEmpty {
                        freehandPoints.append(imagePoint(value.startLocation, scale: scale))
                    }
                    freehandPoints.append(imagePoint(value.location, scale: scale))
                }
            }
            .onEnded { value in
                defer { dragStart = nil; dragCurrent = nil; freehandPoints = [] }
                let start = imagePoint(value.startLocation, scale: scale)
                let end = imagePoint(value.location, scale: scale)
                let moved = hypot(value.translation.width, value.translation.height)

                if tool == .text {
                    beginTextEntry(at: start, scale: scale)
                    return
                }

                if tool == .freehand {
                    guard freehandPoints.count > 2 else { return } // ignore stray clicks
                    let width = strokeWidth.imageWidth(scale: scale)
                    annotations.append(
                        Annotation(kind: .freehand(points: freehandPoints, color: color, width: width))
                    )
                    return
                }

                guard moved > 3 else { return } // ignore stray clicks
                addShape(from: start, to: end, scale: scale)
            }
    }

    private func previewAnnotation(scale: CGFloat) -> Annotation? {
        guard tool != .text else { return nil }
        if tool == .freehand {
            guard freehandPoints.count > 2 else { return nil }
            let width = strokeWidth.imageWidth(scale: scale)
            return Annotation(kind: .freehand(points: freehandPoints, color: color, width: width))
        }
        guard let dragStart, let dragCurrent else { return nil }
        let start = imagePoint(dragStart, scale: scale)
        let end = imagePoint(dragCurrent, scale: scale)
        return shape(from: start, to: end, scale: scale)
    }

    private func shape(from start: CGPoint, to end: CGPoint, scale: CGFloat) -> Annotation? {
        let width = strokeWidth.imageWidth(scale: scale)
        switch tool {
        case .arrow:
            return Annotation(kind: .arrow(start: start, end: end, color: color, width: width))
        case .rectangle:
            return Annotation(kind: .rectangle(rect: markupRect(start, end), color: color, width: width))
        case .highlighter:
            return Annotation(kind: .highlighter(start: start, end: end, color: color, width: width))
        case .blur:
            return Annotation(kind: .blur(rect: markupRect(start, end)))
        case .freehand, .text:
            return nil
        }
    }

    private func addShape(from start: CGPoint, to end: CGPoint, scale: CGFloat) {
        if let annotation = shape(from: start, to: end, scale: scale) {
            annotations.append(annotation)
        }
    }

    private func beginTextEntry(at origin: CGPoint, scale: CGFloat) {
        commitDraft()
        draftText = ""
        draftFontSize = strokeWidth.imageFont(scale: scale)
        draftOrigin = origin
        textFieldFocused = true
    }

    private func commitDraft() {
        defer {
            draftOrigin = nil
            draftText = ""
            textFieldFocused = false
        }
        guard let origin = draftOrigin else { return }
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        annotations.append(
            Annotation(kind: .text(
                origin: origin,
                string: trimmed,
                color: color,
                fontSize: draftFontSize
            ))
        )
    }

    private func undo() {
        commitDraft()
        if !annotations.isEmpty { annotations.removeLast() }
    }

    // MARK: Flatten

    /// Renders the base + annotations at native pixel size. `renderScale` = 1
    /// means the canvas draws the image 1:1, so annotations export crisp.
    private func flatten() -> NSImage? {
        let renderer = ImageRenderer(
            content: MarkupCanvas(
                base: image,
                pixelated: pixelated,
                annotations: annotations,
                preview: nil,
                pixelSize: pixelSize,
                renderScale: 1
            )
        )
        renderer.scale = 1
        return renderer.nsImage ?? image
    }
}

// MARK: - Toolbar button

/// Segmented-feeling tool toggle: accent tint + soft fill when active,
/// hover feedback otherwise. Mirrors GlyphButton's language.
private struct ToolButton: View {
    let symbol: String
    let help: String
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isActive ? Theme.accent : (hovering ? Theme.accent : .primary))
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isActive ? Theme.accentSoft : (hovering ? Theme.accentSoft.opacity(0.5) : .clear))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

#if DEBUG
#Preview {
    let image = NSImage(size: NSSize(width: 640, height: 400), flipped: false) { rect in
        NSColor.systemTeal.setFill()
        rect.fill()
        NSColor.white.setFill()
        NSRect(x: 60, y: 60, width: 200, height: 120).fill()
        return true
    }
    return MarkupEditorView(image: image) { _ in }
        .frame(width: 760, height: 520)
}
#endif
