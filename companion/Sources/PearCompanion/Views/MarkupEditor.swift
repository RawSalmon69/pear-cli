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
    let onFinish: (NSImage?) -> Void

    /// Base image, its pixel size, and its pixelated copy are mutable so a
    /// committed crop can replace them in place.
    @State private var image: NSImage
    @State private var pixelSize: CGSize
    @State private var pixelated: NSImage?

    @State private var annotations: [Annotation] = []
    @State private var tool: MarkupTool = .arrow
    @State private var color: Color = Theme.accent
    @State private var strokeWidth: StrokeWidth = .medium

    /// Pending crop region in image coordinates while the crop tool is active.
    @State private var cropRect: CGRect?

    /// Full editor snapshots for undo, so a single stack covers both
    /// annotation edits and crops (which change the base image too).
    @State private var undoStack: [Snapshot] = []

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
        self.onFinish = onFinish
        _image = State(initialValue: image)
        _pixelSize = State(initialValue: image.pixelSize)
        _pixelated = State(initialValue: Pixelation.pixelated(image))
    }

    /// Undoable editor state. Base image is a reference, so a snapshot is cheap.
    private struct Snapshot {
        let image: NSImage
        let pixelSize: CGSize
        let pixelated: NSImage?
        let annotations: [Annotation]
    }

    private var isCropping: Bool { tool == .crop && cropRect != nil }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.4)
            canvasArea
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // One Esc owner: cancel the pending crop first, otherwise the editor.
        .onExitCommand {
            if isCropping { cancelCrop() } else { onFinish(nil) }
        }
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
                        selectTool(candidate)
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
            .disabled(undoStack.isEmpty)
            .keyboardShortcut("z", modifiers: .command)

            Spacer()

            // Esc is handled by the view's onExitCommand so it can cancel a
            // pending crop first; the button stays for mouse users.
            Button("Cancel") { onFinish(nil) }

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

                if isCropping, let cropRect {
                    CropOverlay(
                        rect: cropRect,
                        scale: scale,
                        imageSize: pixelSize,
                        onChange: { self.cropRect = $0 }
                    )
                }
            }
            .frame(width: displaySize.width, height: displaySize.height)
            .contentShape(Rectangle())
            .gesture(canvasGesture(scale: scale))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if isCropping { cropConfirmBar.padding(.bottom, Theme.sectionGap) }
            }
        }
        .padding(Theme.sectionGap)
    }

    private var cropConfirmBar: some View {
        HStack(spacing: 10) {
            if let cropRect {
                Text("\(Int(cropRect.width.rounded())) × \(Int(cropRect.height.rounded()))")
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button { cancelCrop() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Cancel crop (Esc)")

            Button { commitCrop() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
            .help("Apply crop (Return)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCard(cornerRadius: 12)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
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
                guard tool != .text, tool != .crop else { return }
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
                guard tool != .crop else { return } // crop is driven by the overlay
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
                    pushUndo()
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
        guard tool != .text, tool != .crop else { return nil }
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
        case .freehand, .text, .crop:
            return nil
        }
    }

    private func addShape(from start: CGPoint, to end: CGPoint, scale: CGFloat) {
        if let annotation = shape(from: start, to: end, scale: scale) {
            pushUndo()
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
        pushUndo()
        annotations.append(
            Annotation(kind: .text(
                origin: origin,
                string: trimmed,
                color: color,
                fontSize: draftFontSize
            ))
        )
    }

    // MARK: Crop

    private func selectTool(_ candidate: MarkupTool) {
        commitDraft()
        if candidate == .crop {
            cropRect = clampCropRect(CGRect(origin: .zero, size: pixelSize), to: pixelSize)
        } else {
            cropRect = nil
        }
        tool = candidate
    }

    private func commitCrop() {
        guard tool == .crop, let rect = cropRect else { return }
        let clamped = clampCropRect(rect, to: pixelSize)
        guard clamped.width >= 1, clamped.height >= 1,
              let cropped = ImageCrop.crop(image, to: clamped) else {
            cancelCrop()
            return
        }
        pushUndo()
        image = cropped
        pixelSize = cropped.pixelSize
        pixelated = Pixelation.pixelated(cropped)
        let offset = CGSize(width: -clamped.minX, height: -clamped.minY)
        annotations = annotations.map { $0.translated(by: offset) }
        cropRect = nil
        tool = .arrow
    }

    private func cancelCrop() {
        cropRect = nil
        tool = .arrow
    }

    // MARK: Undo

    private func pushUndo() {
        undoStack.append(Snapshot(image: image, pixelSize: pixelSize,
                                  pixelated: pixelated, annotations: annotations))
    }

    private func undo() {
        commitDraft()
        guard let last = undoStack.popLast() else { return }
        image = last.image
        pixelSize = last.pixelSize
        pixelated = last.pixelated
        annotations = last.annotations
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

// MARK: - Crop overlay

/// Dimmed-outside crop affordance: a bright selection rect with a rule-of-thirds
/// grid, eight resize handles, a draggable body, and drag-to-draw on the dimmed
/// area. Geometry is image-space; the view scales it by `scale`.
private struct CropOverlay: View {
    let rect: CGRect          // image coordinates
    let scale: CGFloat
    let imageSize: CGSize
    let onChange: (CGRect) -> Void

    @State private var dragStartRect: CGRect?

    private static let minSize: CGFloat = 20 // image px
    private static let space = "cropOverlay"

    private var bounds: CGRect { CGRect(origin: .zero, size: imageSize) }
    private var viewRect: CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale,
               width: rect.width * scale, height: rect.height * scale)
    }

    var body: some View {
        let vr = viewRect
        ZStack(alignment: .topLeading) {
            // Dimming with the selection punched out; drag here to draw anew.
            Canvas { ctx, size in
                var path = Path(CGRect(origin: .zero, size: size))
                path.addRect(vr)
                ctx.fill(path, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
            }
            .contentShape(Rectangle())
            .gesture(drawGesture)

            // Draggable body (moves the whole rect).
            Color.white.opacity(0.001)
                .frame(width: vr.width, height: vr.height)
                .offset(x: vr.minX, y: vr.minY)
                .gesture(bodyGesture)

            gridAndBorder(vr)
                .allowsHitTesting(false)

            ForEach(CropHandle.allCases, id: \.self) { handle in
                handleView
                    .position(x: vr.minX + handle.unit.x * vr.width,
                              y: vr.minY + handle.unit.y * vr.height)
                    .gesture(handleGesture(handle))
            }
        }
        .coordinateSpace(name: Self.space)
    }

    private func gridAndBorder(_ vr: CGRect) -> some View {
        ZStack {
            Path { p in
                for i in 1...2 {
                    let x = vr.minX + vr.width * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: vr.minY)); p.addLine(to: CGPoint(x: x, y: vr.maxY))
                    let y = vr.minY + vr.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: vr.minX, y: y)); p.addLine(to: CGPoint(x: vr.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.4), lineWidth: 0.75)

            Rectangle()
                .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.5)
                .frame(width: vr.width, height: vr.height)
                .offset(x: vr.minX, y: vr.minY)
        }
    }

    private var handleView: some View {
        ZStack {
            Color.white.opacity(0.001).frame(width: 30, height: 30) // generous hit area
            Circle()
                .fill(.white)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }
        .contentShape(Rectangle())
    }

    private func handleGesture(_ handle: CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let p = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
                onChange(handle.resize(rect, to: p, in: bounds, minSize: Self.minSize))
            }
    }

    private var bodyGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let start = dragStartRect ?? rect
                if dragStartRect == nil { dragStartRect = rect }
                var moved = start.offsetBy(dx: value.translation.width / scale,
                                           dy: value.translation.height / scale)
                moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
                moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
                onChange(moved)
            }
            .onEnded { _ in dragStartRect = nil }
    }

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let a = CGPoint(x: value.startLocation.x / scale, y: value.startLocation.y / scale)
                let b = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
                onChange(clampCropRect(markupRect(a, b), to: imageSize))
            }
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
