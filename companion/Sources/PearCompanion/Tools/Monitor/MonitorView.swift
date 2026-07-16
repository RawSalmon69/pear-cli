import SwiftUI

/// The Monitor popover: live CPU / memory / network / battery / sensor detail.
/// ~360 pt wide. Each section renders only when its sampler returned data, so
/// desktops drop the battery card and machines without readable sensors drop
/// the sensors card, with no error surfaced.
struct MonitorView: View {
    @State private var model = MonitorModel()
    @State private var showSettings = false

    private var snap: MonitorSnapshot { model.snapshot }
    private var visible: Set<MonitorSection> { model.prefs.visibleSections }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.itemGap) {
                header
                if showSettings { MonitorSettingsStrip(model: model) }
                content
            }
            .padding(14)
        }
        // Fills the Monitor window; also fine at the old ~360 pt in narrow
        // hosts since it just expands to whatever the window gives it.
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    /// A single right-aligned gear that reveals the inline settings strip —
    /// no separate window, matching the panel's own settings affordance.
    private var header: some View {
        HStack {
            Spacer()
            GlyphButton(
                symbol: "slider.horizontal.3",
                help: "Customize",
                tint: showSettings ? Theme.accent : .secondary
            ) {
                showSettings.toggle()
            }
        }
    }

    @ViewBuilder private var content: some View {
        if visible.isEmpty {
            // Every section is off — a quiet nudge instead of a blank window.
            VStack(spacing: 6) {
                Image(systemName: "eye.slash")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                Text("Everything's hidden — turn a section on")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
        } else {
            if snap.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Sampling…").font(Theme.body).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
            }
            // Gate on the live visible set as well as the sampled value, so
            // toggling a section off hides it instantly rather than at the
            // next tick.
            if visible.contains(.cpu), let cpu = snap.cpu { CPUCard(sample: cpu) }
            if visible.contains(.memory), let memory = snap.memory { MemoryCard(sample: memory) }
            if visible.contains(.network), let network = snap.network { NetworkCard(sample: network) }
            if visible.contains(.battery), let battery = snap.battery { BatteryCard(sample: battery) }
            if visible.contains(.sensors), let sensors = snap.sensors { SensorsCard(sample: sensors) }
        }
    }
}

/// The inline customization strip: one switch per section plus the refresh-rate
/// steps. Bound straight to the live `MonitorModel`, so every change persists
/// and applies immediately through the model's `prefs` setter.
private struct MonitorSettingsStrip: View {
    @Bindable var model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Sections")
            ForEach(MonitorSection.allCases) { section in
                Toggle(section.title, isOn: binding(for: section))
                    .font(Theme.body)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Theme.accent)
            }

            Divider().padding(.vertical, 2)

            SectionLabel(text: "Refresh")
            Picker("Refresh", selection: $model.prefs.refreshRate) {
                ForEach(MonitorRefreshRate.allCases) { rate in
                    Text(rate.title).tag(rate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12)
    }

    private func binding(for section: MonitorSection) -> Binding<Bool> {
        Binding(
            get: { model.prefs.visibleSections.contains(section) },
            set: { on in
                if on {
                    model.prefs.visibleSections.insert(section)
                } else {
                    model.prefs.visibleSections.remove(section)
                }
            })
    }
}

// MARK: - Building blocks

/// A titled glass card, the layout unit every section reuses.
private struct MonitorCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: title)
            content
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12)
    }
}

/// A thin capsule fill, 0…1.
private struct MiniBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.5))
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

/// A proportional multi-segment bar (memory breakdown).
private struct StackedBar: View {
    /// (fraction 0…1, color), rendered left to right.
    let segments: [(Double, Color)]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    Rectangle()
                        .fill(seg.1)
                        .frame(width: max(0, geo.size.width * min(1, max(0, seg.0))))
                }
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
    }
}

/// A label plus a monospaced-digit value on one line.
private struct MetricRow: View {
    let label: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        HStack {
            Text(label).font(Theme.body).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(Theme.rounded(13, .medium))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
    }
}

// MARK: - CPU

private struct CPUCard: View {
    let sample: CPUSample

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        MonitorCard(title: "CPU") {
            HStack(spacing: 8) {
                MiniBar(fraction: sample.total, tint: barTint(sample.total))
                Text(MonitorFormat.percent(sample.total))
                    .font(Theme.rounded(13, .semibold))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(sample.cores) { core in
                    HStack(spacing: 6) {
                        Text("\(core.id)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 16, alignment: .trailing)
                        MiniBar(fraction: core.usage, tint: barTint(core.usage))
                        Text(MonitorFormat.percent(core.usage))
                            .font(.system(size: 9, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func barTint(_ v: Double) -> Color { v > 0.85 ? Theme.warn : Theme.accent }
}

// MARK: - Memory

private struct MemoryCard: View {
    let sample: MemorySample

    var body: some View {
        MonitorCard(title: "Memory") {
            StackedBar(segments: segments)
            MetricRow(label: "Used", value: MonitorFormat.gib(sample.used))
            MetricRow(label: "Free", value: MonitorFormat.gib(sample.free))
            HStack(spacing: 12) {
                Text("wired \(MonitorFormat.gib(sample.wired))")
                Text("compressed \(MonitorFormat.gib(sample.compressed))")
            }
            .font(Theme.caption)
            .foregroundStyle(.tertiary)
        }
    }

    private var segments: [(Double, Color)] {
        let total = Double(max(sample.total, 1))
        let wired = Double(sample.wired)
        let compressed = Double(sample.compressed)
        let app = max(0, Double(sample.used) - wired - compressed)
        let free = Double(sample.free)
        return [
            (app / total, Theme.accent),
            (wired / total, Theme.accent.opacity(0.5)),
            (compressed / total, Theme.warn.opacity(0.7)),
            (free / total, Color.secondary.opacity(0.25)),
        ]
    }
}

// MARK: - Network

private struct NetworkCard: View {
    let sample: NetworkSample

    var body: some View {
        MonitorCard(title: "Network") {
            MetricRow(
                label: "Download", value: MonitorFormat.rate(sample.downBytesPerSec),
                tint: Theme.accent)
            MetricRow(
                label: "Upload", value: MonitorFormat.rate(sample.upBytesPerSec),
                tint: Theme.accent)
            if let name = sample.interfaceName {
                Text(name).font(Theme.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Battery

private struct BatteryCard: View {
    let sample: BatterySample

    var body: some View {
        MonitorCard(title: sample.isCharging ? "Battery — charging" : "Battery") {
            if let percent = sample.percent {
                MetricRow(label: "Charge", value: "\(percent)%")
            }
            if let health = sample.healthPercent {
                MetricRow(label: "Health", value: "\(health)%")
            }
            if let cycles = sample.cycleCount {
                MetricRow(label: "Cycles", value: "\(cycles)")
            }
            if let minutes = sample.timeRemainingMinutes {
                MetricRow(
                    label: sample.isCharging ? "To full" : "Remaining",
                    value: MonitorFormat.duration(minutes: minutes))
            }
            if let watts = sample.chargingWatts {
                MetricRow(label: "Adapter", value: String(format: "%.0f W", watts))
            }
        }
    }
}

// MARK: - Sensors

private struct SensorsCard: View {
    let sample: SensorSample

    var body: some View {
        MonitorCard(title: "Sensors") {
            ForEach(sample.temperatures) { reading in
                MetricRow(label: reading.label, value: String(format: "%.0f°C", reading.value))
            }
            ForEach(sample.fans) { reading in
                MetricRow(label: reading.label, value: "\(Int(reading.value)) rpm")
            }
        }
    }
}
