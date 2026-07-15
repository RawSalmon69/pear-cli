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
            ToolsSection()
            StatsSection()
            BottomBar()
        }
        .padding(16)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
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
                    Text("Your disk is getting full — a clean would help")
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

/// Data-driven from the tool registry: one tile per registered tool.
struct ToolsSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var activePopoverID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Tools")
            // Four tiles per row; extra tools wrap instead of squeezing.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.itemGap), count: 4),
                      spacing: Theme.itemGap) {
                ForEach(env.tools.all, id: \.id) { tool in
                    tile(for: tool)
                }
            }
        }
    }

    @ViewBuilder
    private func tile(for tool: any Tool) -> some View {
        switch tool.entry {
        case .action(let run):
            ToolTile(symbol: tool.icon, label: tool.title, hint: tool.hotkey?.label, action: run)
        case .popover(let content):
            ToolTile(symbol: tool.icon, label: tool.title, hint: tool.hotkey?.label) {
                activePopoverID = tool.id
            }
            .popover(
                isPresented: Binding(
                    get: { activePopoverID == tool.id },
                    set: { if !$0 { activePopoverID = nil } }
                ),
                arrowEdge: .bottom
            ) { content() }
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
            VStack(spacing: 4) {
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
            .frame(height: 58)
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

struct StatsSection: View {
    @Environment(AppEnvironment.self) private var env
    private let refreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            HStack {
                SectionLabel(text: "Mac")
                Spacer()
                if let uptime = env.stats.uptime {
                    Text("up \(uptime)")
                        .font(Theme.caption)
                        .foregroundStyle(.quaternary)
                }
            }

            if env.stats.cliMissing {
                HStack(spacing: 6) {
                    Image(systemName: "terminal").foregroundStyle(.tertiary)
                    Text("Install the pear CLI to see disk, memory, CPU, and battery")
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                }
                .padding(Theme.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()
            } else {
                let tiles = env.stats.items
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.itemGap), count: 4),
                          spacing: Theme.itemGap) {
                    ForEach(tiles, id: \.label) { StatTile(stat: $0) }
                }
            }
        }
        .onReceive(refreshTimer) { _ in
            Task { await env.stats.refresh() }
        }
    }
}

struct StatTile: View {
    let stat: StatItem

    private var ringColor: Color {
        guard let fraction = stat.fraction else { return Theme.accent }
        if stat.label.hasPrefix("Batt") || stat.label == "Charging" {
            return fraction < 0.2 ? Theme.warn : Theme.accent
        }
        return fraction > 0.9 ? Theme.warn : Theme.accent
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(.quaternary.opacity(0.6), lineWidth: 3)
                if let fraction = stat.fraction {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.6), value: fraction)
                }
                Image(systemName: stat.symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 30, height: 30)
            Text(stat.value)
                .font(Theme.rounded(12, .semibold))
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(stat.label)
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .glassCard(cornerRadius: 12)
    }
}

// MARK: - Bottom bar

struct BottomBar: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: Theme.itemGap) {
            Button { env.cleaner.run(command: "clean") } label: {
                Label("Clean", systemImage: "sparkles").font(Theme.body)
            }
            Button { env.cleaner.run(command: "optimize") } label: {
                Label("Optimize", systemImage: "wind").font(Theme.body)
            }
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
            GlyphButton(symbol: "gearshape.fill", help: "Settings", tint: .secondary) {
                showSettings = true
            }
            .popover(isPresented: $showSettings) { SettingsPopover() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(Theme.accent)
        // Kill the key-focus ring that made the first button look selected.
        .focusEffectDisabled()
    }
}
