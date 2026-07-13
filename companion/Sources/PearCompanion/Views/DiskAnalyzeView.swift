import SwiftUI
import AppKit

/// Native disk-usage visualization backed by `pear analyze --json`. Opens on
/// the storage overview and drills into directories one level at a time, with a
/// Back path stack. Self-contained: owns its service and fits a ~340 pt panel
/// or a small window.
struct DiskAnalyzeView: View {
    @StateObject private var service = DiskAnalyzeService()
    /// Directories drilled into, deepest last. Empty == the overview.
    @State private var pathStack: [String] = []

    init() {}

    private var maxEntrySize: Int64 {
        service.entries.map(\.size).max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            header
            content
        }
        .padding(16)
        .frame(width: 340)
        .task {
            if service.entries.isEmpty && service.errorMessage == nil {
                await service.scan(path: nil)
            }
        }
        .animation(.easeOut(duration: 0.2), value: service.entries)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.itemGap) {
            if !pathStack.isEmpty {
                GlyphButton(symbol: "chevron.left", help: "Back", tint: .secondary) {
                    goBack()
                }
                .disabled(service.isLoading)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(pathStack.isEmpty ? "Storage" : locationTitle)
                    .font(Theme.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            GlyphButton(symbol: "arrow.clockwise", help: "Rescan", tint: .secondary) {
                Task { await service.scan(path: pathStack.last) }
            }
            .disabled(service.isLoading)
        }
    }

    private var locationTitle: String {
        guard let path = service.currentPath else { return "Storage" }
        return (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent
    }

    private var subtitle: String {
        if service.isOverview {
            return "\(ByteFormat.si(service.totalSize)) across top categories"
        }
        if let path = service.currentPath {
            return "\(ByteFormat.si(service.totalSize)) · \(displayPath(path))"
        }
        return ByteFormat.si(service.totalSize)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if service.isLoading && service.entries.isEmpty {
            loadingCard
        } else if let message = service.errorMessage {
            errorCard(message)
        } else if service.entries.isEmpty {
            emptyCard
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    VStack(spacing: 6) {
                        ForEach(service.entries) { entry in
                            EntryBar(
                                entry: entry,
                                maxSize: maxEntrySize,
                                totalSize: service.totalSize,
                                canDrill: entry.isDir && !service.isLoading,
                                onDrill: { drill(into: entry) }
                            )
                        }
                    }

                    if !service.largeFiles.isEmpty {
                        largestFiles
                    }
                }
                .padding(.bottom, 2)
            }
            .frame(maxHeight: 420)
            .opacity(service.isLoading ? 0.5 : 1)
        }
    }

    private var largestFiles: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Largest files")
            VStack(spacing: 4) {
                ForEach(service.largeFiles) { file in
                    LargeFileRow(file: file)
                }
            }
        }
    }

    // MARK: States

    private var loadingCard: some View {
        VStack(spacing: Theme.itemGap) {
            ProgressView()
                .controlSize(.small)
            Text("Measuring disk usage…")
                .font(Theme.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(Theme.heroPadding)
        .glassCard(cornerRadius: 16)
    }

    private var emptyCard: some View {
        VStack(spacing: 6) {
            Image(systemName: "internaldrive")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("Nothing to show here")
                .font(Theme.emphasis)
            Text("This location is empty or too small to measure.")
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(Theme.heroPadding)
        .glassCard(cornerRadius: 16)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            Label("Can't analyze right now", systemImage: "exclamationmark.triangle.fill")
                .font(Theme.emphasis)
                .foregroundStyle(Theme.warn)
            Text(message)
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") {
                Task { await service.scan(path: pathStack.last) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.heroPadding)
        .glassCard(cornerRadius: 16)
    }

    // MARK: Navigation

    private func drill(into entry: DiskEntry) {
        guard entry.isDir, !service.isLoading else { return }
        pathStack.append(entry.path)
        Task { await service.scan(path: entry.path) }
    }

    private func goBack() {
        guard !pathStack.isEmpty else { return }
        pathStack.removeLast()
        Task { await service.scan(path: pathStack.last) }
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty, path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Entry bar

/// A proportional horizontal bar for one entry: name, human size, share of
/// total, and a width proportional to size. Warn-tinted when very large or
/// cleanable; directories are tappable to drill in.
private struct EntryBar: View {
    let entry: DiskEntry
    let maxSize: Int64
    let totalSize: Int64
    let canDrill: Bool
    let onDrill: () -> Void

    @State private var hovering = false

    private var fractionOfMax: Double {
        guard maxSize > 0 else { return 0 }
        return min(1, Double(entry.size) / Double(maxSize))
    }

    private var shareOfTotal: Double {
        guard totalSize > 0 else { return 0 }
        return Double(entry.size) / Double(totalSize)
    }

    private var isVeryLarge: Bool { shareOfTotal >= 0.5 }

    private var barColor: Color {
        (entry.cleanable || isVeryLarge) ? Theme.warn : Theme.accent
    }

    private var percentText: String {
        let percent = shareOfTotal * 100
        if percent > 0 && percent < 0.1 { return "< 0.1%" }
        return String(format: "%.1f%%", percent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: entry.isDir ? "folder.fill" : "doc.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(barColor)
                Text(entry.name)
                    .font(Theme.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if entry.cleanable {
                    CleanableBadge()
                }
                Spacer(minLength: 4)
                Text(ByteFormat.si(entry.size))
                    .font(Theme.rounded(12, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.5))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(3, geo.size.width * fractionOfMax))
                }
            }
            .frame(height: 6)

            HStack(spacing: 4) {
                Text(percentText)
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                GlyphButton(symbol: "magnifyingglass", help: "Reveal in Finder", tint: .secondary) {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: entry.path)]
                    )
                }
                if canDrill {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(Theme.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(hovering && canDrill ? Theme.accentSoft : .clear)
        )
        .glassCard(cornerRadius: 12)
        .contentShape(Rectangle())
        .onTapGesture { if canDrill { onDrill() } }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Small "cleanable" pill, warm so it advances against the glass.
private struct CleanableBadge: View {
    var body: some View {
        Text("cleanable")
            .font(Theme.rounded(9, .semibold))
            .kerning(0.3)
            .foregroundStyle(Theme.warn)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.warn.opacity(0.16)))
    }
}

// MARK: - Large file row

private struct LargeFileRow: View {
    let file: DiskFile

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(file.name)
                .font(Theme.body)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(ByteFormat.si(file.size))
                .font(Theme.rounded(12, .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            GlyphButton(symbol: "magnifyingglass", help: "Reveal in Finder", tint: .secondary) {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: file.path)]
                )
            }
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 8)
        .glassCard(cornerRadius: 10)
    }
}
