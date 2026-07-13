import SwiftUI
import AppKit

/// Panel layout in spec order. Function over beauty — a design pass restyles
/// every row; this wiring pass only makes the pipe usable end to end.
struct PanelView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderSection()
            ConnectionBanner()
            MessagesSection()
            ShelfSection()
            StatsSection()
            ActionsSection()
            FooterSection()
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { markVisibleSeen() }
    }

    /// Incoming messages currently visible count as seen. The service ignores
    /// our own messages and ones already receipted.
    private func markVisibleSeen() {
        let visible = Array(env.messaging.messages.prefix(10))
        Task {
            for message in visible {
                try? await env.messaging.markSeen(message)
            }
        }
    }
}

struct HeaderSection: View {
    var body: some View {
        HStack {
            Text("🍐")
                .font(.largeTitle)
            Text("Pear")
                .font(.system(.title2, design: .rounded).weight(.semibold))
            Spacer()
        }
    }
}

/// Setup card / offline strip. Stub visuals — the design pass restyles.
struct ConnectionBanner: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        switch env.messaging.connectionState {
        case .needsSetup:
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up your couple key")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                Text("Add the shared key to the Keychain on both Macs (service com.rawsalmon69.pear.companion, account couple-key), then relaunch. Notes stay private to the two of you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        case .offline(let reason):
            Label(reason, systemImage: "icloud.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .connecting, .online:
            EmptyView()
        }
    }
}

struct MessagesSection: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var draft = ""

    private var recent: [Message] {
        Array(env.messaging.messages.filter { $0.kind != .file }.prefix(10))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)

            if recent.isEmpty {
                Text("No notes yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(recent) { message in
                        MessageRow(message: message)
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("Write a note…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    Task { try? await env.messaging.sendPoke() }
                } label: {
                    Text("🍐")
                }
                .help("Poke")
                Button("Screenshot") {
                    Task { await env.screenshot.capture() }
                }
                .help("Region screenshot (⌃⇧P)")
            }
        }
        .padding(10)
        .glassCard()
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        draft = ""
        Task { try? await env.messaging.send(text: text) }
    }
}

struct MessageRow: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                switch message.kind {
                case .text:
                    Text(message.text ?? "")
                        .font(.system(.callout, design: .rounded))
                case .poke:
                    Text("poked you 🍐")
                        .font(.system(.callout, design: .rounded))
                case .image:
                    if let url = message.assetURL, let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Label(message.text ?? "photo", systemImage: "photo")
                            .font(.system(.callout, design: .rounded))
                    }
                case .file:
                    Label(message.text ?? "file", systemImage: "doc")
                        .font(.system(.callout, design: .rounded))
                }
                HStack(spacing: 4) {
                    Text(message.sentAt, style: .time)
                    if message.seenAt != nil {
                        Text("seen 🍐")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct ShelfSection: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var isTargeted = false

    private var shelfItems: [Message] {
        Array(env.messaging.messages.filter { $0.kind == .file }.prefix(20))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shelf")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)

            if shelfItems.isEmpty {
                Text("Drop a file to share it")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shelfItems) { item in
                        ShelfRow(item: item)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isTargeted ? Color.accentColor : .clear, lineWidth: 2)
        )
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL }
            guard !files.isEmpty else { return false }
            Task {
                for url in files {
                    try? await env.messaging.send(fileAt: url, kind: .file)
                }
            }
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}

struct ShelfRow: View {
    let item: Message

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)
            Text(item.text ?? "file")
                .font(.system(.callout, design: .rounded))
                .lineLimit(1)
            Spacer()
            if let url = item.assetURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
            }
        }
    }
}

struct StatsSection: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        HStack(spacing: 8) {
            ForEach(env.stats.current(), id: \.label) { stat in
                VStack {
                    Image(systemName: stat.symbol)
                    Text(stat.value)
                        .font(.system(.callout, design: .rounded).weight(.medium))
                    Text(stat.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(8)
                .glassCard(cornerRadius: 10)
            }
        }
    }
}

struct ActionsSection: View {
    var body: some View {
        HStack {
            Button("Clean Now") {}
            Button("Optimize") {}
        }
        .buttonStyle(.bordered)
    }
}

struct FooterSection: View {
    var body: some View {
        HStack {
            Text("Pear \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }
}
