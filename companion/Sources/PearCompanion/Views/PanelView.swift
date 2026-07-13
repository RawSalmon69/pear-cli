import SwiftUI
import AppKit

/// The panel. Hierarchy is carried by whitespace (20 pt between sections,
/// 8 pt within) and one dominant element: the latest note from the other
/// side, shown as the hero card. Everything else supports it.
struct PanelView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            HeaderSection()
            ConnectionBanner()
            NotesSection()
            ShelfSection()
            StatsSection()
            BottomBar()
        }
        .padding(16)
        .frame(width: 360)
        .task {
            await env.messaging.refresh()
            await env.stats.refresh()
            markVisibleSeen()
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
    @EnvironmentObject private var env: AppEnvironment

    private var mood: MascotMood {
        if let fraction = env.diskUsedFraction, fraction > 0.9 { return .worried }
        if env.hasUnseenIncoming { return .excited }
        return .idle
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            MascotView(mood: mood)
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting(role: CoupleKey.deviceRole))
                    .font(Theme.title)
                if mood == .worried {
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
    @EnvironmentObject private var env: AppEnvironment
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
    @EnvironmentObject private var env: AppEnvironment
    @State private var draft = ""

    private var thread: [Message] {
        Array(env.messaging.messages.filter { $0.kind != .file }.prefix(8))
    }

    /// The dominant element: newest note from the other side.
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

/// Her latest note, big and warm.
struct HeroNoteCard: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MessageBody(message: message, font: Theme.emphasis, imageHeight: 140)
            HStack(spacing: 4) {
                Text(message.sentAt, style: .time)
                if message.seenAt != nil { Text("· seen 🍐") }
            }
            .font(Theme.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(Theme.heroPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16)
        .overlay(alignment: .topTrailing) {
            Text("🍐")
                .font(.system(size: 12))
                .padding(8)
                .opacity(0.6)
        }
    }
}

struct CompactNoteRow: View {
    let message: Message

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
            Text(message.sentAt, style: .time)
                .font(Theme.caption)
                .foregroundStyle(.quaternary)
        }
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
            Text(message.text ?? "").font(font)
        case .poke:
            Text("poke 🍐").font(font)
        case .image:
            if let url = message.assetURL, let image = NSImage(contentsOf: url) {
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
    @EnvironmentObject private var env: AppEnvironment
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
                .background(
                    Capsule().fill(.quaternary.opacity(0.5))
                )
            GlyphButton(symbol: "paperplane.fill", help: "Send", tint: empty ? .secondary : Theme.accent) {
                send()
            }
            .disabled(empty)
            GlyphButton(symbol: "hand.point.right.fill", help: "Poke 🍐") {
                Task { try? await env.messaging.sendPoke() }
            }
            GlyphButton(symbol: "camera.viewfinder", help: "Screenshot — copies, saves, and can send (⌃⇧P)") {
                Task { await env.screenshot.capture() }
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

// MARK: - Shelf

struct ShelfSection: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var isTargeted = false

    private var shelfItems: [Message] {
        Array(env.messaging.messages.filter { $0.kind == .file }.prefix(20))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Shelf")

            Group {
                if shelfItems.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down")
                            .foregroundStyle(.tertiary)
                        Text("Drop a file here — it lands on both your shelves")
                            .font(Theme.body)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(shelfItems) { ShelfRow(item: $0) }
                    }
                }
            }
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        isTargeted ? Theme.accent : .clear,
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
            )
            .animation(.easeOut(duration: 0.15), value: isTargeted)
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter { $0.isFileURL }
                guard !files.isEmpty else { return false }
                Task {
                    for url in files {
                        try? await env.messaging.send(fileAt: url, kind: .file)
                    }
                }
                return true
            } isTargeted: { isTargeted = $0 }
        }
    }
}

struct ShelfRow: View {
    let item: Message

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text ?? "file")
                    .font(Theme.body)
                    .lineLimit(1)
                Text(item.sentAt, style: .relative)
                    .font(Theme.caption)
                    .foregroundStyle(.quaternary)
            }
            Spacer()
            if let url = item.assetURL {
                GlyphButton(symbol: "magnifyingglass", help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }
}

// MARK: - Stats

struct StatsSection: View {
    @EnvironmentObject private var env: AppEnvironment

    private let refreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Mac")

            if env.statsCLIMissing {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .foregroundStyle(.tertiary)
                    Text("Install the pear CLI to see disk, memory, and battery here")
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                }
                .padding(Theme.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()
            } else {
                HStack(spacing: Theme.itemGap) {
                    ForEach(env.stats.current(), id: \.label) { StatTile(stat: $0) }
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
        // Battery rings drain; disk/memory rings fill. High fill = warning.
        if stat.label.hasPrefix("Batt") || stat.label == "Charging" {
            return fraction < 0.2 ? Theme.warn : Theme.accent
        }
        return fraction > 0.9 ? Theme.warn : Theme.accent
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(.quaternary.opacity(0.6), lineWidth: 3)
                if let fraction = stat.fraction {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.6), value: fraction)
                }
                Image(systemName: stat.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 34, height: 34)
            Text(stat.value)
                .font(Theme.rounded(13, .semibold))
                .contentTransition(.numericText())
            Text(stat.label)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 12)
    }
}

// MARK: - Bottom bar

struct BottomBar: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: Theme.itemGap) {
            Button {
                TerminalRunner.run("clean")
            } label: {
                Label("Clean", systemImage: "sparkles")
                    .font(Theme.body)
            }
            Button {
                TerminalRunner.run("optimize")
            } label: {
                Label("Optimize", systemImage: "wind")
                    .font(Theme.body)
            }
            Spacer()
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .font(Theme.caption)
                .foregroundStyle(.quaternary)
            GlyphButton(symbol: "gearshape.fill", help: "Settings", tint: .secondary) {
                showSettings = true
            }
            .popover(isPresented: $showSettings) { SettingsPopover() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(Theme.accent)
        .disabled(false)
    }
}
