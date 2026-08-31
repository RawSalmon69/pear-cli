import SwiftUI

/// The Monitor popover: live CPU / memory / network / battery / sensor detail.
/// ~360 pt wide. Each section renders only when its sampler returned data, so
/// desktops drop the battery card and machines without readable sensors drop
/// the sensors card, with no error surfaced.
struct MonitorView: View {
    @State private var model: MonitorModel
    @State private var showSettings = false

    /// The model is injected (by `MonitorWindowController`) so the controller
    /// can drive the same `stop()` from `windowWillClose` that `.onDisappear`
    /// calls — a hosted SwiftUI view's `onDisappear` isn't guaranteed to fire
    /// when the AppKit window closes.
    init(model: MonitorModel) {
        _model = State(initialValue: model)
    }

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
            if visible.contains(.processes), let processes = snap.processes {
                TopProcessesCard(sample: processes, metric: $model.processMetric)
            }
            if visible.contains(.cpu), let cpu = snap.cpu {
                CPUCard(sample: cpu, history: model.cpuHistory.values)
            }
            if visible.contains(.memory), let memory = snap.memory {
                MemoryCard(sample: memory, history: model.memoryHistory.values)
            }
            if visible.contains(.network), let network = snap.network {
                NetworkCard(
                    sample: network,
                    download: model.netDownHistory.values,
                    upload: model.netUpHistory.values)
            }
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
                    .focusable(false)
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
            .focusable(false)
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


// MARK: - Top Processes

/// The attribution table: which apps are actually spending the machine, ranked
/// by one metric at a time, with helper processes summed into the app that
/// spawned them. Deliberately the head of the list and nothing more — the tail
/// of a process table is hundreds of idle daemons.
private struct TopProcessesCard: View {
    let sample: ProcessSample
    @Binding var metric: ProcessMetric

    var body: some View {
        MonitorCard(title: "Top Processes") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $metric) {
                    ForEach(ProcessMetric.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)

                if sample.groups.isEmpty {
                    Text("Nothing readable yet")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sample.groups) { group in
                        ProcessRow(group: group, metric: metric, peak: peak)
                    }
                }

                Divider()
                Text(footer)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Bars are scaled to the top row, not to the machine: ranked by disk or
    /// wakeups there is no natural ceiling, and against a machine-wide maximum
    /// every bar would be a sliver.
    private var peak: Double {
        max(sample.groups.map { metric.value($0) }.max() ?? 0, .leastNonzeroMagnitude)
    }

    private var footer: String {
        let busy = String(format: "%.0f%%", sample.busyFraction * 100)
        var parts = [
            "\(busy) of \(sample.coreCount) cores",
            "\(sample.processCount) processes",
            "\(sample.threadCount) threads",
        ]
        if sample.hiddenGroupCount > 0 {
            parts.append("\(sample.hiddenGroupCount) more apps below")
        }
        return parts.joined(separator: " · ")
    }
}

/// One app: name, how many processes it is, its value, and a bar for scanning
/// the ranking without reading the numbers.
private struct ProcessRow: View {
    let group: ProcessGroup
    let metric: ProcessMetric
    let peak: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(group.name)
                    .font(Theme.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if group.processCount > 1 {
                    Text("\(group.processCount)")
                        .font(Theme.rounded(10, .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .help("\(group.processCount) processes rolled up")
                }
                Spacer(minLength: 6)
                Text(metric.label(for: group))
                    .font(Theme.rounded(12, .medium))
                    .monospacedDigit()
            }
            MiniBar(fraction: min(1, metric.value(group) / peak), tint: Theme.accent)
        }
    }
}

// MARK: - CPU

private struct CPUCard: View {
    let sample: CPUSample
    /// Total-load history, oldest → newest (0…1).
    let history: [Double]

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
            if history.count >= 2 {
                TrendChart(values: history, tint: Theme.accent)
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
    /// Used-fraction history, oldest → newest (0…1).
    let history: [Double]

    var body: some View {
        MonitorCard(title: "Memory") {
            StackedBar(segments: segments)
            if history.count >= 2 {
                TrendChart(values: history, tint: Theme.accent)
            }
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
    /// Throughput history, oldest → newest (bytes/sec).
    let download: [Double]
    let upload: [Double]

    var body: some View {
        MonitorCard(title: "Network") {
            MetricRow(
                label: "Download", value: MonitorFormat.rate(sample.downBytesPerSec),
                tint: Theme.accent)
            MetricRow(
                label: "Upload", value: MonitorFormat.rate(sample.upBytesPerSec),
                tint: Theme.warn)
            if download.count >= 2 || upload.count >= 2 {
                NetworkTrendChart(
                    download: download, upload: upload,
                    downTint: Theme.accent, upTint: Theme.warn)
            }
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
