import SwiftUI
import AppKit

/// The panel: the cat and a search field on top, the four pinned tiles, the
/// recent captures, then one compact list of every other enabled tool.
/// `PanelModel` makes every decision (tiles, rows, selection, what a key does,
/// the cat's line); this view renders it and forwards keys.
struct PanelView: View {
    @Environment(AppEnvironment.self) private var env
    /// Closes the panel. Esc on an empty search calls it.
    let close: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @State private var pins = Prefs.pinnedTools()
    @State private var pickYourFourDismissed = Prefs.isPickYourFourDismissed()
    @State private var popovers = TilePopoverState()
    /// Read and checked against the disk once per open; the view is rebuilt
    /// for every open.
    @State private var recentCaptures = Prefs.recentCaptures()
    /// Read once per open too, with no prompt; a recorded capture failure clears
    /// here once preflight passes.
    @State private var screenRecordingMissing = Permissions.screenRecordingMissing()
    @State private var accessibilityTrusted = Permissions.accessibilityTrusted

    /// Tools with a row, in offer order. `all` already applies the enabled and
    /// paywall gates.
    private var tools: [any Tool] { env.tools.all.filter(\.showsTile) }

    /// Any enabled capture mode can open a recent capture; with all three off
    /// the strip has nothing to open it with, so it hides.
    private var captureTool: ScreenshotTool? {
        env.tools.all.lazy.compactMap { $0 as? ScreenshotTool }.first
    }

    private var model: PanelModel {
        PanelModel(
            entries: tools.map {
                PanelModel.Entry(
                    id: $0.id, title: $0.title, icon: $0.icon, summary: $0.summary,
                    aliases: $0.aliases, shortcut: env.tools.hotkeyLabel(for: $0.id))
            },
            problems: PanelProblem.current(
                diskUsedFraction: env.stats.diskUsedFraction,
                screenRecordingMissing: screenRecordingMissing,
                accessibilityTrusted: accessibilityTrusted,
                enabledTools: Set(tools.map(\.id))),
            pins: pins,
            pickYourFourDismissed: pickYourFourDismissed,
            recentCaptures: captureTool == nil ? [] : recentCaptures,
            hasUnseenNote: FeatureFlags.coupleNote && env.hasUnseenIncoming,
            query: query,
            selection: selection)
    }

    var body: some View {
        let model = model
        VStack(alignment: .leading, spacing: Theme.Space.large) {
            PanelHeader(model: model, onKey: send, onFix: fix)
            if FeatureFlags.coupleNote {
                ConnectionBanner()
                NotesSection()
            }
            // `unlocksTools` is false exactly when the entitlement is `.expired`,
            // and the reason decides the wording — so match on it here. The list
            // stays below on purpose: while locked it holds only the two tools
            // that survive expiry, and those rows are the user's way back to
            // their own notes and shelf items.
            if case .expired(let reason) = env.entitlement.entitlement {
                LockedStateCard(reason: reason)
            }
            if model.showsPickYourFour {
                PickYourFourCard(dismiss: dismissPickYourFour)
            }
            pinnedRow(model)
            recentStrip(model)
            toolList(model)
            BottomBar()
        }
        .padding(Theme.edgePadding)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        // The panel can be torn down with a popover still up, skipping the
        // popover's dismissal handshake; without this reset the stale ID left
        // that row dead on every reopen.
        .onDisappear { popovers.panelClosed() }
        .task {
            if FeatureFlags.coupleNote {
                await env.messaging.refresh()
                markVisibleSeen()
            }
        }
    }

    // MARK: Keys

    private func send(_ key: PanelModel.Key) {
        var next = model
        let command = next.handle(key)
        query = next.query
        selection = next.selection
        switch command {
        case .run(let id):
            if let tool = tools.first(where: { $0.id == id }) { activate(tool) }
        case .close:
            close()
        case nil:
            break
        }
    }

    /// One path for a click and for Return, so a row behaves the same either way.
    private func activate(_ tool: any Tool) {
        switch tool.entry {
        case .action(let run):
            run()
        case .popover:
            if popovers.request(tool.id) {
                Task { @MainActor in popovers.present(tool.id) }
            }
        }
    }

    /// Closes the panel first: it floats above System Settings.
    private func fix(_ permission: Permission) {
        close()
        Permissions.fix(permission)
    }

    // MARK: Pins

    private func togglePin(_ id: String) {
        var next = model
        next.togglePin(id)
        pins = next.pins
        pickYourFourDismissed = next.pickYourFourDismissed
        selection = next.selection
        Prefs.setPinnedTools(next.pins)
    }

    private func dismissPickYourFour() {
        pickYourFourDismissed = true
        Prefs.dismissPickYourFour()
    }

    @ViewBuilder
    private func pinnedRow(_ model: PanelModel) -> some View {
        if !model.pinned.isEmpty {
            HStack(spacing: Theme.Space.small) {
                ForEach(model.pinned, id: \.id) { entry in
                    if let tool = tools.first(where: { $0.id == entry.id }) {
                        anchored(tool, pinned: model.isPinned(tool.id)) {
                            PinnedTile(entry: entry, selected: entry.id == model.selectedID,
                                       needsPermission: model.needsPermission(entry.id)) {
                                activate(tool)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Recent captures

    /// Click opens the capture in the detail window, closing the panel first
    /// (it floats above that window); drag hands out the file. Deferred a turn:
    /// the click arrives inside the panel that `close` tears down.
    @ViewBuilder
    private func recentStrip(_ model: PanelModel) -> some View {
        if !model.recents.isEmpty {
            let tool = captureTool
            HStack(spacing: Theme.Space.small) {
                ForEach(model.recents, id: \.self) { url in
                    RecentCaptureTile(url: url) {
                        Task { @MainActor in
                            close()
                            tool?.openCapture(url)
                        }
                    }
                }
            }
            .background(WindowMoveBlocker())
        }
    }

    // MARK: List

    @ViewBuilder
    private func toolList(_ model: PanelModel) -> some View {
        if model.showsNoMatch {
            VStack(spacing: Theme.Space.small) {
                Text("No tools match")
                    .font(Theme.Typography.body())
                    .foregroundStyle(.secondary)
                // A tool that is switched off does not show here; Tools is
                // where it is switched back on.
                Button("Open Settings") { SettingsPage.open(.tools) }
                    .font(Theme.Typography.small())
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.large)
        } else {
            VStack(spacing: 0) {
                ForEach(model.rows, id: \.id) { entry in
                    if let tool = tools.first(where: { $0.id == entry.id }) {
                        anchored(tool, pinned: model.isPinned(tool.id)) {
                            ToolRow(entry: entry, status: tool.status,
                                    selected: entry.id == model.selectedID,
                                    needsPermission: model.needsPermission(entry.id)) {
                                activate(tool)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A tile or a row: the right-click Pin / Unpin, and a popover tool's popover
    /// anchored to it. A tool is never a tile and a row at once, so it has one anchor.
    @ViewBuilder
    private func anchored(_ tool: any Tool, pinned: Bool,
                          @ViewBuilder _ anchor: () -> some View) -> some View {
        let view = anchor().contextMenu {
            Button(pinned ? "Unpin" : "Pin") { togglePin(tool.id) }
        }
        if case .popover(let content) = tool.entry {
            view.popover(
                isPresented: Binding(
                    get: { popovers.activeID == tool.id },
                    set: { if !$0 { popovers.dismissed(tool.id) } }
                ),
                arrowEdge: .bottom
            ) {
                content()
                    .onAppear { popovers.didPresent(tool.id) }
                    .onDisappear { popovers.didDismiss(tool.id) }
            }
        } else {
            view
        }
    }

    private func markVisibleSeen() {
        let visible = Array(env.messaging.messages.prefix(10))
        Task {
            for message in visible {
                try? await env.messaging.markSeen(message)
            }
        }
    }
}

// MARK: - Header

/// The cat beside the search field, with the cat's line under the field: the
/// top current problem, or nothing at all, and Fix beside a permission problem.
struct PanelHeader: View {
    let model: PanelModel
    let onKey: (PanelModel.Key) -> Void
    let onFix: (Permission) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.medium) {
            MascotView(mood: model.mood)
                .frame(width: 54, alignment: .leading)
            VStack(alignment: .leading, spacing: Theme.Space.xSmall) {
                HStack(spacing: Theme.Space.small) {
                    Image(systemName: "magnifyingglass")
                        .font(Theme.Typography.body())
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    PanelSearchField(text: model.query, onKey: onKey)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, Theme.Space.small)
                .padding(.vertical, Theme.Space.xSmall)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.small)
                        .fill(.quaternary.opacity(0.5))
                )
                if !model.catLine.isEmpty {
                    HStack(spacing: Theme.Space.small) {
                        Text(model.catLine)
                            .font(Theme.Typography.small(.semibold))
                            .foregroundStyle(Theme.warn)
                            .lineLimit(1)
                        if let permission = model.fix {
                            Button("Fix") { onFix(permission) }
                                .font(Theme.Typography.small(.semibold))
                                .controlSize(.small)
                                .accessibilityLabel("Fix: open \(permission.paneName) settings")
                        }
                    }
                }
            }
        }
    }
}

/// The search box, in AppKit because its delegate's `doCommandBy` is the one
/// dependable place to see ↑ ↓ ↩ and Esc while the field editor has focus. Each
/// is forwarded to the model and swallowed, so Esc never also reaches the
/// panel's own `cancelOperation` and closes it behind the model's back.
struct PanelSearchField: NSViewRepresentable {
    let text: String
    let onKey: (PanelModel.Key) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = AutoFocusTextField()
        field.placeholderString = "Search tools"
        field.setAccessibilityLabel("Search tools")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        field.font = base.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: base.pointSize) } ?? base
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onKey = onKey
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onKey: onKey) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onKey: (PanelModel.Key) -> Void

        init(onKey: @escaping (PanelModel.Key) -> Void) { self.onKey = onKey }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onKey(.typed(field.stringValue))
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let key: PanelModel.Key
            switch selector {
            case #selector(NSResponder.moveUp(_:)): key = .up
            case #selector(NSResponder.moveDown(_:)): key = .down
            case #selector(NSResponder.insertNewline(_:)): key = .enter
            case #selector(NSResponder.cancelOperation(_:)): key = .escape
            default: return false
            }
            onKey(key)
            return true
        }
    }
}

/// Takes first responder once it is in a window, so typing lands in the search
/// the moment the panel opens. Deferred a turn: the controller makes the panel
/// key only after installing its content.
private final class AutoFocusTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}

/// Setup / offline states, designed rather than apologetic.
struct ConnectionBanner: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        switch env.messaging.connectionState {
        case .needsSetup:
            VStack(alignment: .leading, spacing: Theme.itemGap) {
                Label("Two Macs, one key", systemImage: "key.horizontal.fill")
                    .font(Theme.emphasis)
                    .foregroundStyle(Theme.accent)
                Text("Notes are end-to-end encrypted with a key only the two of you hold. Set it up once.")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set up the key…") { SettingsPage.open(.general) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            .padding(Theme.heroPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 16)
        case .offline(let reason):
            Label(reason, systemImage: "icloud.slash")
                .font(Theme.caption)
                .foregroundStyle(Theme.warn)
        case .connecting, .online:
            EmptyView()
        }
    }
}

// MARK: - Notes

struct NotesSection: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""

    private var thread: [Message] {
        Array(env.messaging.messages.filter { $0.kind != .file }.prefix(8))
    }

    private var hero: Message? {
        thread.first { $0.senderDevice != CoupleKey.deviceRole }
    }

    private var rest: [Message] {
        thread.filter { $0.id != hero?.id }.prefix(4).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Notes")

            if let hero {
                HeroNoteCard(message: hero)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            if thread.isEmpty {
                Text("No notes yet.")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else if !rest.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rest) { CompactNoteRow(message: $0) }
                }
                .padding(.leading, 2)
            }

            Composer(draft: $draft)
        }
        .animation(Theme.motion(.spring(response: 0.35, dampingFraction: 0.8), reduce: reduceMotion),
                   value: thread.first?.id)
    }
}

/// Her latest note, big and warm, with a one-tap copy for text.
struct HeroNoteCard: View {
    let message: Message
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MessageBody(message: message, font: Theme.emphasis, imageHeight: 140)
            HStack(spacing: 8) {
                Text(message.sentAt, style: .time)
                if message.seenAt != nil { Text("· seen 🍐") }
                Spacer()
                if message.kind == .text, let text = message.text {
                    Button {
                        copyText(text)
                    } label: {
                        Label(copied ? "Copied" : "Copy",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(Theme.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? Theme.accent : .secondary)
                }
            }
            .font(Theme.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(Theme.heroPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16)
        .overlay(alignment: .topTrailing) {
            Text("🍐").font(.system(size: 12)).padding(8).opacity(0.6)
        }
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copied = true }
    }
}

struct CompactNoteRow: View {
    let message: Message
    @State private var hovering = false

    private var mine: Bool { message.senderDevice == CoupleKey.deviceRole }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(mine ? "you" : "🍐")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
            MessageBody(message: message, font: Theme.body, imageHeight: 60)
                .foregroundStyle(mine ? .secondary : .primary)
            Spacer(minLength: 0)
            if hovering, message.kind == .text, let text = message.text {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy")
                .foregroundStyle(.secondary)
            } else {
                Text(message.sentAt, style: .time)
                    .font(Theme.caption)
                    .foregroundStyle(.quaternary)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// Kind-appropriate body shared by hero and compact rows.
struct MessageBody: View {
    let message: Message
    let font: Font
    let imageHeight: CGFloat

    var body: some View {
        switch message.kind {
        case .text:
            Text(message.text ?? "").font(font).textSelection(.enabled)
        case .poke:
            Text("poke 🍐").font(font)
        case .image:
            // ~330 pt max display width @2x; keeps 5K captures out of memory.
            if let url = message.assetURL, let image = Thumbnail.image(at: url, maxPixel: 660) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: imageHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Label(message.text ?? "photo", systemImage: "photo").font(font)
            }
        case .file:
            Label(message.text ?? "file", systemImage: "doc").font(font)
        }
    }
}

struct Composer: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var draft: String
    @FocusState private var focused: Bool

    private var empty: Bool { draft.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(spacing: 4) {
            TextField("Write a note…", text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .focused($focused)
                .onSubmit(send)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Capsule().fill(.quaternary.opacity(0.5)))
            GlyphButton(symbol: "paperplane.fill", help: "Send",
                        tint: empty ? .secondary : Theme.accent) { send() }
                .disabled(empty)
            GlyphButton(symbol: "hand.point.right.fill", help: "Poke 🍐") {
                Task { try? await env.messaging.sendPoke() }
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        draft = ""
        Task { try? await env.messaging.send(text: text) }
    }
}

// MARK: - Tools

/// Presentation state for the tool-tile popovers, kept as a plain value type
/// so the two failure modes that made tiles read as dead stay pinned by
/// tests: a stale ID surviving the panel closing with a popover up (every
/// same-tile click became a no-op because the ID never changed), and popover
/// A's late dismissal callback wiping out a just-requested popover B.
struct TilePopoverState: Equatable {
    private(set) var activeID: String?
    /// The popover SwiftUI has actually presented, tracked from the content's
    /// onAppear/onDisappear. Distinguishes a genuinely-open popover (plain close
    /// on re-click) from a stale `activeID` SwiftUI no longer shows (re-present).
    private(set) var visibleID: String?

    /// A tile was clicked. Returns true when the caller must re-present on the
    /// next runloop turn. Three cases when the tile is already active:
    /// its popover is visible → a plain close (return false); its ID is stale —
    /// SwiftUI believes it's up but it isn't visible → the ID must publish nil
    /// once before the same ID reads true again (return true).
    mutating func request(_ id: String) -> Bool {
        if activeID == id {
            let wasVisible = visibleID == id
            activeID = nil
            return !wasVisible
        }
        activeID = id
        return false
    }

    /// The deferred half of a `request` that returned true.
    mutating func present(_ id: String) {
        activeID = id
    }

    /// The popover content appeared on screen.
    mutating func didPresent(_ id: String) {
        visibleID = id
    }

    /// The popover content left the screen. Only the owner clears, so a late
    /// callback from an old popover can't wipe a newer one's visibility.
    mutating func didDismiss(_ id: String) {
        if visibleID == id { visibleID = nil }
    }

    /// SwiftUI reported a popover dismissed. A late callback from an old
    /// popover must not clear a newer request, so only the owner clears.
    mutating func dismissed(_ id: String) {
        if activeID == id { activeID = nil }
    }

    /// The panel went away; nothing is presented anymore.
    mutating func panelClosed() {
        activeID = nil
        visibleID = nil
    }
}

/// One tool in the panel list: icon, name, an optional live state, and the
/// shortcut (or "no shortcut"). Flat fill, never glass: it sits on the panel's
/// own glass. Not focusable: the search field's ↑ ↓ ↩ already reach every row,
/// and a Tab stop here would draw a second focus beside the selection.
struct ToolRow: View {
    let entry: PanelModel.Entry
    let status: String?
    let selected: Bool
    var needsPermission = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.small) {
                Image(systemName: entry.icon)
                    .font(Theme.Typography.body(.medium))
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                    .frame(width: Theme.Space.large)
                Text(entry.title)
                    .font(Theme.Typography.body())
                Spacer(minLength: Theme.Space.small)
                if let status {
                    Text(status)
                        .font(Theme.Typography.small(.medium))
                        .foregroundStyle(Theme.accent)
                }
                if needsPermission {
                    Text("needs permission")
                        .font(Theme.Typography.small(.medium))
                        .foregroundStyle(Theme.warn)
                } else {
                    Text(entry.shortcutText)
                        .font(Theme.Typography.small())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Theme.Space.small)
            .padding(.vertical, Theme.Space.xSmall)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small)
                    .fill(selected ? Theme.accentSoft : hovering ? Theme.accentSoft.opacity(0.5) : .clear)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(entry.title)
        .accessibilityValue(
            [status, needsPermission ? "needs permission" : entry.shortcut]
                .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// One pinned tool: big icon, name, and its shortcut in a key label so it is
/// learned by sight. Flat fill, never glass: it sits on the panel's own glass.
/// Not focusable, like `ToolRow`: the search field's arrows walk the tiles.
struct PinnedTile: View {
    let entry: PanelModel.Entry
    let selected: Bool
    var needsPermission = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Space.xSmall) {
                Image(systemName: entry.icon)
                    .font(Theme.Typography.title(.medium))
                    .foregroundStyle(selected ? Theme.accent : .primary)
                    .frame(height: Theme.Space.xLarge)
                Text(entry.title)
                    .font(Theme.Typography.small(.medium))
                    .lineLimit(1)
                if needsPermission {
                    Text("needs permission")
                        .font(Theme.Typography.tiny(.semibold))
                        .foregroundStyle(Theme.warn)
                        .lineLimit(1)
                } else if let shortcut = entry.shortcut {
                    Text(shortcut)
                        .font(Theme.Typography.tiny(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.Space.xSmall)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.small)
                                .strokeBorder(.tertiary)
                        )
                } else {
                    Text(entry.shortcutText)
                        .font(Theme.Typography.tiny())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.small)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .fill(selected ? Theme.accentSoft
                          : hovering ? Theme.accentSoft.opacity(0.5) : Color.primary.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(entry.title)
        .accessibilityLabel(entry.title)
        .accessibilityValue(needsPermission ? "needs permission" : entry.shortcut ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// One recent capture as a small thumbnail, decoded off the main actor with
/// ImageIO downsampling and never the full image. The shelf's AppKit drag
/// overlay carries the click and the drag: SwiftUI's `.onDrag` does not start a
/// session in a non-activating panel. The button under it never sees a click; it
/// is the Tab stop and the VoiceOver press. Flat fill, never glass.
struct RecentCaptureTile: View {
    let url: URL
    let open: () -> Void
    @State private var thumbnail: NSImage?

    /// Three tiles share the 332 pt row, so ~105 pt wide: 240 px stays crisp
    /// at 2x and costs ~150 KB per tile.
    private static let maxPixel = 240

    var body: some View {
        Button(action: open) {
            RoundedRectangle(cornerRadius: Theme.Radius.small)
                .fill(Color.primary.opacity(0.05))
                .frame(height: 64)
                .overlay {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recent capture, \(url.deletingPathExtension().lastPathComponent)")
        .overlay { ShelfDragOverlay(provider: { url }, onClick: open) }
        .help(url.lastPathComponent)
        .task(id: url) {
            let url = url, maxPixel = Self.maxPixel
            thumbnail = await Task.detached(priority: .userInitiated) {
                Thumbnail.image(at: url, maxPixel: maxPixel)
            }.value
        }
    }
}

/// Keeps the panel from moving while the pointer is over the recent-captures
/// strip, so pressing a tile always drags the file, never the panel. The panel
/// moves by its background (`isMovableByWindowBackground`), and the shelf found
/// that a drag view's `mouseDownCanMoveWindow = false` is not reliably honoured
/// under that setting, so this switches the setting itself off before any press
/// can land: on entering the strip, on every move inside it (which also covers
/// a pointer already inside when the panel opens, or a missed enter), and back
/// on when the pointer leaves or the strip goes away (search, teardown). One
/// tracking view behind the whole strip, gaps included, so it is the only
/// writer and no enter/exit ordering between tiles can leave it wrong.
/// Hit-transparent: tracking areas fire on geometry, so the tiles above still
/// get every click.
private struct WindowMoveBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> BlockerView { BlockerView() }
    func updateNSView(_ nsView: BlockerView, context: Context) {}

    final class BlockerView: NSView {
        private var holding = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self))
        }

        override func mouseEntered(with event: NSEvent) { hold(true) }
        override func mouseMoved(with event: NSEvent) { hold(true) }
        override func mouseExited(with event: NSEvent) { hold(false) }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            hold(false)
            super.viewWillMove(toWindow: newWindow)
        }

        private func hold(_ on: Bool) {
            guard on != holding, let window else { return }
            holding = on
            window.isMovableByWindowBackground = !on
        }
    }
}

/// The one-time hint that pins exist. Gone for good once closed or once any pin
/// changes; `PanelModel.showsPickYourFour` decides.
struct PickYourFourCard: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.small) {
            Image(systemName: "pin.fill")
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: Theme.Space.xSmall) {
                Text("Pick your four")
                    .font(Theme.Typography.body(.semibold))
                Text("Right-click any tool to pin it to the top, or unpin one you don't use.")
                    .font(Theme.Typography.small())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(Theme.Typography.small(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(Theme.Space.medium)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .fill(Theme.accentSoft)
        )
    }
}

// MARK: - Stats

// MARK: - Bottom bar

struct BottomBar: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            buttonRow
            trialNotice
        }
    }

    /// The trial's last few days, said in exactly one place: a footnote under the
    /// panel's own chrome, next to the version and the gear that opens the licence
    /// pane. Not a modal, not a badge, and nothing at all until day three — the
    /// point is that a user who is fine can ignore it and a user who is deciding
    /// knows where to go.
    @ViewBuilder private var trialNotice: some View {
        if case .trial(let days) = env.entitlement.entitlement,
            let notice = LockedCopy.trialNotice(daysRemaining: days) {
            HStack(spacing: 4) {
                Text(notice)
                    .foregroundStyle(.tertiary)
                Link("Buy a licence", destination: LockedCopy.pricingURL)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }
            .font(Theme.caption)
        }
    }

    private var buttonRow: some View {
        HStack(spacing: Theme.itemGap) {
            Spacer()
            if let updater = env.updater {
                Button("v\(updater.versionString)") { updater.checkForUpdates() }
                    .buttonStyle(.plain)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .help("Check for updates")
            } else {
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(Theme.caption)
                    .foregroundStyle(.quaternary)
            }
            GlyphButton(symbol: "questionmark", help: "What can Pear do?", tint: .secondary) {
                showHelp = true
            }
            .popover(isPresented: $showHelp) {
                HelpView(known: env.tools.known, onClose: { showHelp = false })
            }
            GlyphButton(symbol: "gearshape.fill", help: "Settings (⌘,)", tint: .secondary) {
                SettingsPage.open()
            }
            GlyphButton(symbol: "power", help: "Quit Pear", tint: .secondary) {
                NSApp.terminate(nil)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(Theme.accent)
    }
}
