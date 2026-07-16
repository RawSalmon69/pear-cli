import ApplicationServices
import SwiftUI

/// The Windows popover: an Accessibility onboarding card until permission is
/// granted, then a zone grid laid out as a mini window map. Every grid button
/// runs the same `WindowEngine.apply` the global chords do.
struct WindowsView: View {
    // `AXIsProcessTrusted()` is a plain, non-isolated C call — safe to read
    // straight into `@State` and re-poll on appear.
    @State private var trusted = AXIsProcessTrusted()
    @AppStorage(RadialTriggerKey.defaultsKey)
    private var radialTriggerKey = RadialTriggerKey.fnGlobe.rawValue

    // Live per-tool settings (windows.*). Every control applies at use time —
    // the ring/preview read via @AppStorage, the engine/trigger read
    // WindowSettings — so there is no relaunch.
    @AppStorage(WindowSettings.Key.ringCornerRadius)
    private var ringCornerRadius = WindowSettings.defaultRingCornerRadius
    @AppStorage(WindowSettings.Key.ringThickness)
    private var ringThickness = WindowSettings.defaultRingThickness
    @AppStorage(WindowSettings.Key.previewPadding)
    private var previewPadding = WindowSettings.defaultPreviewPadding
    @AppStorage(WindowSettings.Key.previewBlur)
    private var previewBlur = WindowSettings.defaultPreviewBlur
    @AppStorage(WindowSettings.Key.animationEnabled)
    private var animationEnabled = WindowSettings.defaultAnimationEnabled
    @AppStorage(WindowSettings.Key.animationSpeed)
    private var animationSpeed = WindowSettings.defaultAnimationSpeed.rawValue
    @AppStorage(WindowSettings.Key.triggerDelay)
    private var triggerDelay = WindowSettings.defaultTriggerDelay

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            if trusted {
                grid
            } else {
                PermissionCard { trusted = AXIsProcessTrusted() }
            }
        }
        .padding(14)
        .frame(width: 300)
        // Trust can be granted in System Settings while this popover is open;
        // re-check whenever it reappears.
        .onAppear { trusted = AXIsProcessTrusted() }
    }

    // MARK: - Zone grid (a mini window map)

    private var grid: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            zoneSection("Halves", [.leftHalf, .rightHalf])
            VStack(alignment: .leading, spacing: Theme.itemGap) {
                SectionLabel(text: "Quarters")
                HStack(spacing: Theme.itemGap) {
                    ZoneButton(zone: .topLeftQuarter)
                    ZoneButton(zone: .topRightQuarter)
                }
                HStack(spacing: Theme.itemGap) {
                    ZoneButton(zone: .bottomLeftQuarter)
                    ZoneButton(zone: .bottomRightQuarter)
                }
            }
            zoneSection("Thirds", [.leftThird, .centerThird, .rightThird])
            zoneSection("Two-thirds", [.leftTwoThirds, .rightTwoThirds])
            zoneSection("Size", [.maximize, .center])
            radialSection
            settingsSection
        }
    }

    /// Loop-mirroring live settings: ring geometry, preview look, snap
    /// animation, and the trigger delay. Persisted under "windows.*".
    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            VStack(alignment: .leading, spacing: Theme.itemGap) {
                SectionLabel(text: "Ring")
                slider("Corner radius", $ringCornerRadius, WindowSettings.ringCornerRadiusRange) {
                    "\(Int($0.rounded()))"
                }
                slider("Thickness", $ringThickness, WindowSettings.ringThicknessRange) {
                    "\(Int($0.rounded()))"
                }
            }
            VStack(alignment: .leading, spacing: Theme.itemGap) {
                SectionLabel(text: "Preview")
                slider("Padding", $previewPadding, WindowSettings.previewPaddingRange) {
                    "\(Int($0.rounded()))"
                }
                Toggle("Blur", isOn: $previewBlur)
                    .font(Theme.body)
            }
            VStack(alignment: .leading, spacing: Theme.itemGap) {
                SectionLabel(text: "Snap animation")
                Toggle("Animate snaps", isOn: $animationEnabled)
                    .font(Theme.body)
                Picker("Speed", selection: $animationSpeed) {
                    ForEach(WindowAnimationSpeed.allCases) { speed in
                        Text(speed.label).tag(speed.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .font(Theme.body)
                .disabled(!animationEnabled)
            }
            VStack(alignment: .leading, spacing: Theme.itemGap) {
                SectionLabel(text: "Trigger")
                slider("Delay", $triggerDelay, WindowSettings.triggerDelayRange, step: 0.1) {
                    String(format: "%.1f s", $0)
                }
            }
        }
    }

    /// Dense labeled slider with a right-aligned value readout.
    private func slider(
        _ title: String,
        _ value: Binding<Double>,
        _ range: ClosedRange<Double>,
        step: Double = 1,
        format: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(Theme.body)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(Theme.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    /// The Loop-style ring: pick which held key summons it. Takes effect
    /// immediately (the trigger re-reads the key on every modifier event).
    private var radialSection: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Radial ring")
            Text(
                "Hold the trigger key, aim toward a zone, release to snap. "
                    + "Esc cancels. For Fn / Globe, set \"Press 🌐 key\" to "
                    + "Do Nothing in System Settings → Keyboard."
            )
            .font(Theme.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Picker("Trigger key", selection: $radialTriggerKey) {
                ForEach(RadialTriggerKey.allCases) { key in
                    Text(key.label).tag(key.rawValue)
                }
            }
            .pickerStyle(.menu)
            .font(Theme.body)
        }
    }

    private func zoneSection(_ title: String, _ zones: [WindowZone]) -> some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: title)
            HStack(spacing: Theme.itemGap) {
                ForEach(zones, id: \.self) { ZoneButton(zone: $0) }
            }
        }
    }
}

// MARK: - Zone button

/// A single snap target: a schematic of where the window lands, its name, and
/// the chord that triggers it (blank for grid-only zones).
private struct ZoneButton: View {
    let zone: WindowZone
    @State private var hovering = false

    var body: some View {
        Button { WindowEngine.apply(zone) } label: {
            VStack(spacing: 5) {
                ZoneGlyph(zone: zone)
                    .frame(height: 30)
                Text(zone.label)
                    .font(Theme.caption)
                    .foregroundStyle(.primary)
                Text(zone.hotkeyHint ?? " ")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(hovering ? Theme.accentSoft : Color.secondary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(zone.label)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// The window-map schematic: an outline of the screen with the target region
/// filled. Drawn top-down, so the y-up `unit` fraction is flipped here.
private struct ZoneGlyph: View {
    let zone: WindowZone

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.accent)
                    .frame(width: fill(w, h).width, height: fill(w, h).height)
                    .offset(x: fill(w, h).minX, y: fill(w, h).minY)
            }
        }
        .aspectRatio(1.4, contentMode: .fit)
    }

    /// Target rect in the glyph's top-down space.
    private func fill(_ w: CGFloat, _ h: CGFloat) -> NSRect {
        // `.center` has no fractional rect; show a centered ~60% block.
        let unit = zone.unit ?? NSRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let inset: CGFloat = 2
        let iw = w - inset * 2
        let ih = h - inset * 2
        return NSRect(
            x: inset + unit.minX * iw,
            y: inset + (1 - unit.minY - unit.height) * ih,  // flip y-up → top-down
            width: unit.width * iw,
            height: unit.height * ih
        )
    }
}

// MARK: - Accessibility onboarding

/// Shown until Pear is trusted for Accessibility. Explains why, deep-links to
/// the settings pane, and can re-issue the system prompt.
private struct PermissionCard: View {
    /// Called after the user acts, so the parent can re-read trust state.
    let onRecheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                Text("Accessibility access needed")
                    .font(Theme.emphasis)
            }
            Text(
                "Window snapping moves and resizes other apps' windows, which "
                    + "macOS gates behind Accessibility. Grant Pear access, then "
                    + "the zone grid appears here."
            )
            .font(Theme.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.itemGap) {
                Button("Open Accessibility Settings") { openSettings() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                Button("Prompt Again") { promptForTrust() }
                    .buttonStyle(.bordered)
            }
            .font(Theme.body)
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12)
    }

    private func openSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
            NSWorkspace.shared.open(url)
        }
        onRecheck()
    }

    private func promptForTrust() {
        // The SDK imports `kAXTrustedCheckOptionPrompt` as a mutable global,
        // which Swift 6 rejects as not concurrency-safe. Its value is the stable
        // string "AXTrustedCheckOptionPrompt"; use that directly for the key.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        onRecheck()
    }
}

// MARK: - Labels & hints

private extension WindowZone {
    var label: String {
        switch self {
        case .leftHalf: "Left"
        case .rightHalf: "Right"
        case .topHalf: "Top"
        case .bottomHalf: "Bottom"
        case .topLeftQuarter: "Top Left"
        case .topRightQuarter: "Top Right"
        case .bottomLeftQuarter: "Bottom Left"
        case .bottomRightQuarter: "Bottom Right"
        case .leftThird: "Left ⅓"
        case .centerThird: "Center ⅓"
        case .rightThird: "Right ⅓"
        case .leftTwoThirds: "Left ⅔"
        case .rightTwoThirds: "Right ⅔"
        case .maximize: "Maximize"
        case .center: "Center"
        }
    }

    /// The global chord, mirroring `WindowsTool.chords`. Grid-only zones (the
    /// two-thirds) return `nil`.
    var hotkeyHint: String? {
        switch self {
        case .leftHalf: "⌃⌥←"
        case .rightHalf: "⌃⌥→"
        case .maximize: "⌃⌥↑"
        case .center: "⌃⌥↓"
        case .topLeftQuarter: "⌃⌥U"
        case .topRightQuarter: "⌃⌥I"
        case .bottomLeftQuarter: "⌃⌥J"
        case .bottomRightQuarter: "⌃⌥K"
        case .leftThird: "⌃⌥D"
        case .centerThird: "⌃⌥F"
        case .rightThird: "⌃⌥G"
        // Top/bottom halves are radial-ring-only; two-thirds are grid-only.
        case .leftTwoThirds, .rightTwoThirds, .topHalf, .bottomHalf: nil
        }
    }
}
