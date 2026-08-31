import SwiftUI
import AppKit

/// The panel. Hierarchy is carried by whitespace (20 pt between sections,
/// 8 pt within) and one dominant element: the latest note from the other
/// side, shown as the hero card. Everything else supports it.
struct PanelView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            HeaderSection()
            if FeatureFlags.coupleNote {
                ConnectionBanner()
                NotesSection()
            }
            // `unlocksTools` is false exactly when the entitlement is `.expired`,
            // and the reason decides the wording — so match on it here. The grid
            // stays below on purpose: while locked it holds only the two tools
            // that survive expiry, and those tiles are the user's way back to
            // their own notes and shelf items.
            if case .expired(let reason) = env.entitlement.entitlement {
                LockedStateCard(reason: reason)
            }
            ToolsSection()
            BottomBar()
        }
        .padding(16)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        // The panel is a mouse surface; no control should ever wear a focus
        // ring just because the window became key.
        .focusEffectDisabled()
        .task {
            if FeatureFlags.coupleNote {
                await env.messaging.refresh()
                markVisibleSeen()
            }
            await env.stats.refresh()
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

struct HeaderSection: View {
    @Environment(AppEnvironment.self) private var env

    private var mood: MascotMood {
        if let fraction = env.stats.diskUsedFraction, fraction > 0.9 { return .worried }
        if env.hasUnseenIncoming { return .excited }
        return .idle
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            MascotView(mood: mood)
                .frame(width: 54, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting())
                    .font(Theme.title)
                if let health = env.stats.healthMessage {
                    Text(health)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if mood == .worried {
                    Text("Your disk is nearly full")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.warn)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Setup / offline states, designed rather than apologetic.
struct ConnectionBanner: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showSettings = false

    var body: some View {
        switch env.messaging.connectionState {
        case .needsSetup:
            VStack(alignment: .leading, spacing: Theme.itemGap) {
                Label("Two Macs, one key", systemImage: "key.horizontal.fill")
                    .font(Theme.emphasis)
                    .foregroundStyle(Theme.accent)
                Text("Notes are end-to-end encrypted with a key only you two hold. Set it up once and this panel comes alive.")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set up the key…") { showSettings = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .popover(isPresented: $showSettings) { SettingsPopover() }
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
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            if thread.isEmpty {
                Text("Nothing here yet — say hi 🍐")
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
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: thread.first?.id)
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

/// Data-driven from the tool registry, grouped by category so a dozen tools
/// read as a few labeled rows instead of one wall of tiles.
struct ToolsSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var popovers = TilePopoverState()

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: Theme.itemGap), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            ForEach(ToolCategory.allCases, id: \.self) { category in
                let tools = env.tools.all.filter { $0.category == category && $0.showsTile }
                if !tools.isEmpty {
                    SectionLabel(text: category.title)
                    LazyVGrid(columns: columns, spacing: Theme.itemGap) {
                        ForEach(tools, id: \.id) { tile(for: $0) }
                    }
                }
            }
        }
        // MenuBarExtra can tear the panel down with a popover still up,
        // skipping the popover's dismissal handshake; without this reset the
        // stale ID left that tile dead on every reopen.
        .onDisappear { popovers.panelClosed() }
    }

    @ViewBuilder
    private func tile(for tool: any Tool) -> some View {
        // Effective chord (override or default), read from the registry so a
        // custom shortcut shows on the tile the moment it's set.
        let hint = env.tools.hotkeyLabel(for: tool.id)
        switch tool.entry {
        case .action(let run):
            ToolTile(symbol: tool.icon, label: tool.title, hint: hint) {
                env.usage.recordTileTap(tool.id)
                run()
            }
        case .popover(let content):
            ToolTile(symbol: tool.icon, label: tool.title, hint: hint) {
                env.usage.recordTileTap(tool.id)
                if popovers.request(tool.id) {
                    Task { @MainActor in popovers.present(tool.id) }
                }
            }
            .popover(
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
        }
    }
}

struct ToolTile: View {
    let symbol: String
    let label: String
    let hint: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                Text(label).font(.system(size: 10, weight: .medium, design: .rounded))
                // Always render the hint line (blank when none) so every tile
                // is the same height whether or not it has a shortcut.
                Text(hint ?? " ")
                    .font(.system(size: 8, design: .rounded))
                    .foregroundStyle(.quaternary)
            }
            .foregroundStyle(hovering ? Theme.accent : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .frame(height: 68)
            // Make the whole card hittable — the glass fill alone leaves the
            // padding around the glyph/label dead, which read as a hard-to-hit
            // tile (worst on the wide Windows tile).
            .contentShape(Rectangle())
            .glassCard(cornerRadius: 12)
            .overlay {
                if hovering {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Stats

// MARK: - Bottom bar

struct BottomBar: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showSettings = false
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
            GlyphButton(symbol: "gearshape.fill", help: "Settings", tint: .secondary) {
                showSettings = true
            }
            .popover(isPresented: $showSettings) { SettingsPopover() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(Theme.accent)
        // Kill the key-focus ring that made a button look pre-selected.
        .focusEffectDisabled()
    }
}
