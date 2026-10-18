import SwiftUI
import AppKit

extension Notification.Name {
    /// Opens the Settings window. `PanelController` owns the window, so the
    /// panel's gear, ⌘, and the status-item menu all reach the same one.
    static let pearOpenSettings = Notification.Name("pearOpenSettings")
}

/// The Settings window's sidebar pages: the fixed ones, plus one page per
/// offered tool by tool id. Stored by `rawValue` ("menubar" is "tool.menubar").
enum SettingsPage: Hashable, Identifiable {
    case general, appearance, shortcuts, licence, about
    case tool(String)

    private static let toolPrefix = "tool."
    private static let fixed: [SettingsPage] = [.general, .appearance, .shortcuts, .licence, .about]

    var rawValue: String {
        switch self {
        case .general: "general"
        case .appearance: "appearance"
        case .shortcuts: "shortcuts"
        case .licence: "licence"
        case .about: "about"
        case .tool(let id): Self.toolPrefix + id
        }
    }

    init?(rawValue: String) {
        if rawValue.hasPrefix(Self.toolPrefix) {
            self = .tool(String(rawValue.dropFirst(Self.toolPrefix.count)))
        } else if let page = Self.fixed.first(where: { $0.rawValue == rawValue }) {
            self = page
        } else {
            return nil
        }
    }

    var id: String { rawValue }

    /// Fixed pages only; the sidebar labels a tool page with the tool's own
    /// title and icon.
    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .shortcuts: "Shortcuts"
        case .licence: "Licence"
        case .about: "About"
        case .tool(let id): id
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .shortcuts: "keyboard"
        case .licence: "key"
        case .about: "info.circle"
        case .tool: "square.grid.2x2"
        }
    }

    /// The sidebar: General, Appearance, Shortcuts, one page per offered tool
    /// in offer order (enabled or not), then Licence and About. Licence is
    /// hidden while the app is free: with `FeatureFlags.paywall` off nothing
    /// locks and the trial clock never starts, so the pane would sit there
    /// reporting "14 days left" forever and inviting people to buy something
    /// that is not for sale.
    static func visible(toolIDs: [String]) -> [SettingsPage] {
        [.general, .appearance, .shortcuts] + toolIDs.map(SettingsPage.tool)
            + [.licence, .about].filter { FeatureFlags.paywall || $0 != .licence }
    }

    /// The fixed pages offered, without tool pages.
    static var visible: [SettingsPage] { visible(toolIDs: []) }

    /// A stored page name, or General when it is unknown or not offered — a
    /// caller asking for a hidden page, or the page of a tool no longer
    /// offered, gets General rather than a blank pane.
    static func resolved(_ raw: String?, toolIDs: [String] = []) -> SettingsPage {
        guard let page = raw.flatMap(SettingsPage.init(rawValue:)),
              visible(toolIDs: toolIDs).contains(page)
        else { return .general }
        return page
    }

    /// The first tool page. "Open Settings" under "No tools match" lands here,
    /// where the tool pages (and their on/off switches) begin.
    // TODO(ticket 21): remove; PanelView should open a real page
    @MainActor static var tools: SettingsPage {
        .tool(ToolRegistry.live?.known.first?.id ?? "")
    }

    /// Opens Settings on `page`, or on the last page shown. The open itself is
    /// deferred by the observer, so a caller inside the panel is never torn
    /// down mid-action.
    @MainActor static func open(_ page: SettingsPage? = nil) {
        if let page { Prefs.setSettingsPage(page) }
        NotificationCenter.default.post(name: .pearOpenSettings, object: nil)
    }
}

/// Settings, a standard window with a sidebar (`SettingsWindowController`).
/// General = panel, pins, capture and startup; Appearance = accent and the
/// menu-bar runner; Shortcuts = every key combination; then one page per tool
/// (its on/off switch and every option it has); Licence (paid builds only);
/// About.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    /// Raw, so a page written by `SettingsPage.open` while the window is up
    /// switches it live; `SettingsPage.resolved` keeps it to an offered page.
    @AppStorage(Prefs.settingsPageKey) private var storedPage = SettingsPage.general.rawValue
    @State private var showAccentWheel = false
    @State private var confirmResetShortcuts = false
    @State private var keyField = ""
    @State private var role = CoupleKey.deviceRole
    @State private var keyStatus: String?
    @State private var folder = ScreenshotNaming.folder(
        defaults: .standard,
        home: FileManager.default.homeDirectoryForCurrentUser
    ).path
    @AppStorage(Prefs.soundsKey) private var soundsEnabled = true
    @AppStorage(Prefs.autoSaveKey) private var autoSave = true
    @AppStorage(Prefs.previewAutoDismissKey) private var previewAutoDismiss = false
    @AppStorage(Prefs.previewAutoDismissSecondsKey) private var previewAutoDismissSeconds = 6.0
    @AppStorage(Prefs.previewMaxStackKey) private var previewMaxStack = 5
    @AppStorage(Prefs.panelClosesOnFocusLossKey) private var panelClosesOnFocusLoss = true
    @AppStorage(Prefs.hdBackgroundRemovalKey) private var hdEnabled = false
    @State private var hd = HDBackgroundModelManager.shared
    /// Read once per open (the root view is rebuilt each open from closed).
    @State private var pins = Prefs.pinnedTools()

    private var toolIDs: [String] { env.tools.known.map(\.id) }

    private var page: SettingsPage { SettingsPage.resolved(storedPage, toolIDs: toolIDs) }

    private var selection: Binding<SettingsPage?> {
        Binding(
            get: { page },
            set: { if let new = $0 { storedPage = new.rawValue } }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(SettingsPage.visible(toolIDs: toolIDs)) { page in
                    if case .tool(let id) = page, let tool = knownTool(id) {
                        Label(tool.title, systemImage: tool.icon).tag(page)
                    } else {
                        Label(page.title, systemImage: page.icon).tag(page)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    switch page {
                    case .general: generalPage
                    case .appearance: appearancePage
                    case .shortcuts: shortcutsPage
                    case .tool(let id):
                        // `resolved` only returns a tool page for a known id.
                        if let tool = knownTool(id) { toolPage(tool) }
                    case .licence:
                        // Unreachable while free (`resolved` never returns it),
                        // kept as a second guard.
                        if FeatureFlags.paywall { LicenceSettingsView() } else { generalPage }
                    case .about: aboutPage
                    }
                }
                .padding(Theme.Space.xLarge)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 600, minHeight: 440)
    }

    @ViewBuilder private var backgroundRemovalSection: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Background removal")
            Toggle("High-quality mode", isOn: $hdEnabled)
                .font(Theme.body)
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .onChange(of: hdEnabled) { _, _ in hd.prepare() }
            Text(hdEnabled
                ? "On-device AI model for remove.bg-class cutouts (hair, fine edges). One-time \(HDBackgroundModelManager.downloadSizeText) download; fully offline after."
                : "Apple's built-in cutout is instant and needs no download. Turn this on for sharper edges, after a one-time \(HDBackgroundModelManager.downloadSizeText) download.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if hdEnabled { hdStatusRow }
        }
    }

    @ViewBuilder private var hdStatusRow: some View {
        switch hd.state {
        case .absent:
            Button("Download model (\(HDBackgroundModelManager.downloadSizeText))") { hd.download() }
                .font(Theme.caption)
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction).tint(Theme.accent)
                Text(hd.progressText ?? "Downloading…")
                    .font(Theme.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing…").font(Theme.caption).foregroundStyle(.secondary)
            }
        case .ready:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Ready · high quality").font(Theme.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Remove") { hd.remove() }
                    .font(Theme.caption)
                    .help("Delete the model and its compiled copy")
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(Theme.caption).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { hd.download() }.font(Theme.caption)
            }
        }
    }

    @ViewBuilder private var generalPage: some View {
        if FeatureFlags.coupleNote {
            coupleKeySection
        }

        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Panel")
            Toggle("Close when it loses focus", isOn: $panelClosesOnFocusLoss)
                .font(Theme.body)
                .toggleStyle(.switch)
                .tint(Theme.accent)
            Text("When off, the panel stays open until you click the menu-bar icon or press Esc. Drag it by any empty area.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        pinsSection

        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Startup")
            Toggle("Open at login", isOn: loginItemBinding)
                .font(Theme.body)
                .toggleStyle(.switch)
                .tint(Theme.accent)
        }

        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Feedback")
            Toggle("Sound effects", isOn: $soundsEnabled)
                .font(Theme.body)
                .toggleStyle(.switch)
                .tint(Theme.accent)
        }

        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Screenshots")
            Text("Captures are copied to the clipboard and saved here.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Toggle("Save a copy to this folder", isOn: $autoSave)
                .font(Theme.body)
                .toggleStyle(.switch)
                .tint(Theme.accent)
            HStack(spacing: 6) {
                Text(folder)
                    .font(Theme.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(autoSave ? .secondary : .quaternary)
                Spacer()
                Button("Change…") { pickFolder() }
                    .font(Theme.caption)
                    .disabled(!autoSave)
            }
        }

        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Preview stack")
            Text("Previews stack in the corner and stay until you swipe them away.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Stepper(value: $previewMaxStack, in: 1...10) {
                Text("Keep up to \(previewMaxStack) previews")
                    .font(Theme.body)
            }
            Toggle("Auto-dismiss after a delay", isOn: $previewAutoDismiss)
                .font(Theme.body)
                .toggleStyle(.switch)
                .tint(Theme.accent)
            Stepper(value: $previewAutoDismissSeconds, in: 2...60, step: 1) {
                Text("Dismiss after \(Int(previewAutoDismissSeconds))s")
                    .font(Theme.caption)
                    .foregroundStyle(previewAutoDismiss ? .secondary : .quaternary)
            }
            .disabled(!previewAutoDismiss)
        }

        backgroundRemovalSection
    }

    /// Accent colour and the menu-bar runner. Named Appearance so "Menu Bar"
    /// means only the menu-bar hider tool.
    @ViewBuilder private var appearancePage: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Accent")
            HStack(spacing: 8) {
                ForEach(AccentPreset.allCases) { preset in
                    AccentSwatch(
                        preset: preset,
                        selected: ThemeStore.shared.custom == nil && ThemeStore.shared.preset == preset
                    ) {
                        ThemeStore.shared.custom = nil
                        ThemeStore.shared.preset = preset
                    }
                }
                // Not a SwiftUI ColorPicker and not the system color panel —
                // owner wants one simple wheel, inline. (It also dodged the
                // color panel dismissing the old transient popover.)
                Button {
                    showAccentWheel.toggle()
                } label: {
                    Circle()
                        .fill(AngularGradient(
                            colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                            center: .center))
                        .frame(width: 20, height: 20)
                        .overlay {
                            if ThemeStore.shared.custom != nil {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Custom color")
            }
            if showAccentWheel {
                AccentWheel { ThemeStore.shared.custom = $0 }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }

        RunnerSettingsView(runner: env.runner)
    }

    /// Reads/writes the login-item state straight from `SMAppService` (its
    /// status is the source of truth), so the toggle reflects reality even if
    /// login items were changed in System Settings.
    private var loginItemBinding: Binding<Bool> {
        Binding(get: { LoginItem.isEnabled }, set: { LoginItem.setEnabled($0) })
    }

    private func knownTool(_ id: String) -> ToolRegistry.KnownTool? {
        env.tools.known.first { $0.id == id }
    }

    /// One tool's page: its on/off switch, then every option it has. Options
    /// live only here; the tool's popover or window keeps its working controls
    /// and a "Settings…" link back (`ToolSettingsLink`).
    @ViewBuilder private func toolPage(_ tool: ToolRegistry.KnownTool) -> some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            Toggle(isOn: toolBinding(tool.id)) {
                Label(tool.title, systemImage: tool.icon)
                    .font(Theme.emphasis)
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
            if !tool.summary.isEmpty {
                Text(tool.summary)
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("A tool you turn off does not load at all. Changes apply immediately.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
        }

        toolStatus(tool)

        toolOptions(tool.id)
    }

    /// Why a tool might not be working: its permission, whether the system took
    /// its shortcut, and the last failure it reported (no row when there is
    /// none). The error redraws live; the permission is read on each render and
    /// so is current every time the window opens.
    @ViewBuilder private func toolStatus(_ tool: ToolRegistry.KnownTool) -> some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Status")
            statusRow("Permission", permissionStatus(tool.id))
            statusRow("Shortcut", shortcutStatus(tool.id))
            if let error = env.tools.lastError(for: tool.id) {
                statusRow("Last error", (error, true))
            }
        }
    }

    private func statusRow(_ label: String, _ value: (text: String, problem: Bool)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.small) {
            Text(label)
                .font(Theme.body)
                .frame(width: 120, alignment: .leading)
            Text(value.text)
                .font(Theme.body)
                .foregroundStyle(value.problem ? Theme.warn : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value.text)")
    }

    private func permissionStatus(_ id: String) -> (text: String, problem: Bool) {
        guard let permission = PanelProblem.permission(neededBy: id) else { return ("None needed", false) }
        let name = permission.paneName
        return switch Permissions.status(of: permission) {
        case .granted: ("\(name) granted", false)
        case .missing: ("\(name) missing", true)
        case .unconfirmed: ("\(name) is checked at the first capture", false)
        }
    }

    private func shortcutStatus(_ id: String) -> (text: String, problem: Bool) {
        switch env.tools.shortcutStatus(for: id) {
        case .notOffered:
            id == WindowsTool.toolID ? ("Snap shortcuts are on the Shortcuts page", false) : ("None for this tool", false)
        case .none: ("None set", false)
        case .toolOff(let chord): ("\(chord), not registered while the tool is off", false)
        case .registered(let chord): ("\(chord) registered", false)
        case .notRegistered(let chord): ("\(chord) not registered; another app may be using it", true)
        }
    }

    /// The options of the tools that have any; every other page is just the switch.
    @ViewBuilder private func toolOptions(_ id: String) -> some View {
        switch id {
        case MenuBarTool.toolID:
            // The live tool even while off, so a change made now is the one it
            // starts with; its setters only touch a surface that is installed.
            if let menuBar = env.tools.offeredTool(id) as? MenuBarTool {
                MenuBarOptionsView(manager: menuBar.manager)
            }
        case SwitchesTool.toolID: SwitchesVisibilityView()
        case ScratchpadTool.toolID: ScratchpadSettingsView()
        case ColorPickerTool.toolID: ColorFormatPicker()
        case CleanModeTool.toolID: CleanModeSettingsView()
        default: EmptyView()
        }
    }

    /// The panel's four pinned tiles, slot by slot, from the enabled tools that
    /// have a tile. `PanelModel` decides what each slot shows and what a pick
    /// stores, so this row is exactly the panel's. The panel closes when
    /// Settings opens and reads pins on every open, so the next open shows it.
    @ViewBuilder private var pinsSection: some View {
        let model = PanelModel(
            entries: env.tools.all.filter(\.showsTile).map {
                PanelModel.Entry(id: $0.id, title: $0.title, icon: $0.icon, summary: $0.summary)
            },
            problems: [], pins: pins)
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Pinned tools")
            Text("The big tiles at the top of the panel. Pick a tool already pinned to swap the two.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(model.pinned.enumerated()), id: \.offset) { slot, entry in
                Picker("Tile \(slot + 1)", selection: Binding(
                    get: { entry.id },
                    set: { id in
                        pins = model.pins(placing: id, inSlot: slot)
                        Prefs.setPinnedTools(pins)
                    }
                )) {
                    ForEach(model.entries, id: \.id) { tool in
                        Label(tool.title, systemImage: tool.icon).tag(tool.id)
                    }
                }
                .font(Theme.body)
                .frame(maxWidth: 320)
            }
        }
    }

    /// Every key combination in Pear: each tool that can take a shortcut
    /// (`acceptsHotkey`; Switches, Windows and Highlight Copy get no recorder),
    /// then each Windows snap chord by action name.
    @ViewBuilder private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Tools")
            Text("Click a shortcut, then press the new keys with at least one of ⌃ ⌥ ⇧ ⌘. Esc cancels; Delete on its own removes the shortcut. Changes apply immediately.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(env.tools.known.filter(\.acceptsHotkey), id: \.id) { tool in
                shortcutRow(owner: .tool(tool.id), name: tool.title) {
                    Label(tool.title, systemImage: tool.icon)
                }
            }
        }

        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Windows")
            Text("Snap the front window. These work while the Windows tool is on.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(WindowSettings.chordDefaults) { binding in
                let name = RingLabel.text(for: binding.action)
                shortcutRow(owner: .windows(binding.id), name: name) { Text(name) }
            }
        }

        Button("Reset All Shortcuts…") { confirmResetShortcuts = true }
            .font(Theme.body)
            .help("Put every tool and Windows shortcut back to its default")
            .confirmationDialog(
                "Reset all shortcuts to their defaults?", isPresented: $confirmResetShortcuts
            ) {
                Button("Reset All Shortcuts", role: .destructive) { env.tools.resetAllShortcuts() }
            } message: {
                Text("Every changed or removed shortcut, including the Windows ones, goes back to its default.")
            }
    }

    private func shortcutRow(
        owner: ShortcutOwner, name: String, @ViewBuilder label: () -> some View
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.small) {
            label()
                .font(Theme.body)
                .frame(width: 200, alignment: .leading)
            HotkeyRecorderRow(owner: owner, name: name)
        }
    }

    private func toolBinding(_ id: String) -> Binding<Bool> {
        Binding(
            // Observable, not a raw UserDefaults read: see KnownTool.isEnabled.
            get: { env.tools.isEnabled(id) },
            set: { env.tools.setEnabled(id, $0) }
        )
    }

    @ViewBuilder private var aboutPage: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Pear")
            Text("Version \(Self.version)")
                .font(Theme.body)
                .textSelection(.enabled)
            if let updater = env.updater {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .font(Theme.body)
            }
        }

        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Licences and notices")
            Text("Pear includes work from these projects.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            // Shown inline, not opened in a text editor: the files live inside
            // the signed app bundle, and saving an edit there breaks the seal.
            ForEach(Self.notices, id: \.url) { notice in
                DisclosureGroup(notice.title) {
                    ScrollView {
                        Text((try? String(contentsOf: notice.url, encoding: .utf8)) ?? "")
                            .font(Theme.Typography.small())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 180)
                }
                .font(Theme.body)
            }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        guard let build = info?["CFBundleVersion"] as? String else { return short }
        return "\(short) (\(build))"
    }

    /// Every bundled licence and notice file: `Resources/Licenses/` plus the
    /// runner artwork's `Resources/Runners/*.txt`.
    private static let notices: [(title: String, url: URL)] = {
        ["Licenses", "Runners"].flatMap { folder -> [URL] in
            guard let dir = Bundle.pearResources.url(forResource: folder, withExtension: nil),
                  let files = try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil)
            else { return [] }
            return files.filter { $0.pathExtension == "txt" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        .map { url in
            let name = url.deletingPathExtension().lastPathComponent
            return (name == "NOTICE" ? "Runner artwork (NOTICE)" : name, url)
        }
    }()

    private var coupleKeySection: some View {
            VStack(alignment: .leading, spacing: Theme.itemGap) {
                SectionLabel(text: "Couple key")
                Text("Generate on one Mac, paste it on the other, then relaunch.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    SecureField("Paste key…", text: $keyField)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.body)
                    Button("Save") {
                        if CoupleKey.store(base64Key: keyField.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            keyStatus = "Saved. Relaunch Pear to connect."
                            keyField = ""
                        } else {
                            keyStatus = "That doesn't look like a valid key"
                        }
                    }
                    .disabled(keyField.isEmpty)
                }
                Button("Generate new key (copies to clipboard)") {
                    let key = CoupleKey.generate()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                    if CoupleKey.store(base64Key: key) {
                        keyStatus = "Generated + saved here. Paste it on the other Mac."
                    }
                }
                .font(Theme.caption)
                if let keyStatus {
                    Text(keyStatus)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.accent)
                }
                Picker("I am", selection: $role) {
                    Text("raws").tag("raws")
                    Text("Pear 🍐").tag("pear")
                }
                .pickerStyle(.segmented)
                .onChange(of: role) { _, newRole in CoupleKey.store(role: newRole) }
            }
    }

    /// The inline hue/saturation wheel behind the custom-accent swatch: tap or
    /// drag anywhere on the disc, the accent recolors live as you move. Angle
    /// is hue, distance from center is saturation, brightness stays vivid —
    /// the math lives in `AccentWheelMath` (pure, tested).
    private struct AccentWheel: View {
        let onPick: (Color) -> Void

        private static let diameter: CGFloat = 140

        var body: some View {
            Circle()
                .fill(AngularGradient(
                    colors: (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) },
                    center: .center))
                .overlay(
                    Circle().fill(RadialGradient(
                        colors: [.white, .white.opacity(0)], center: .center,
                        startRadius: 0, endRadius: Self.diameter / 2)))
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { apply(at: $0.location) }
                        .onEnded { apply(at: $0.location) }
                )
        }

        private func apply(at point: CGPoint) {
            let size = CGSize(width: Self.diameter, height: Self.diameter)
            guard let pick = AccentWheelMath.pick(at: point, in: size) else { return }
            onPick(Color(hue: pick.hue, saturation: pick.saturation, brightness: 1))
        }
    }

    private struct AccentSwatch: View {
        let preset: AccentPreset
        let selected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Circle()
                    .fill(preset.color)
                    .frame(width: 20, height: 20)
                    .overlay {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(preset.name)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: "screenshotFolder")
            folder = url.path
        }
    }
}

/// A tool popover's or window's link to that tool's Settings page, where its
/// options live.
struct ToolSettingsLink: View {
    let toolID: String
    let title: String

    var body: some View {
        Button("Settings…") { SettingsPage.open(.tool(toolID)) }
            .buttonStyle(.link)
            .font(Theme.caption)
            .focusable(false)
            .help("Open \(title) in Settings")
            .accessibilityLabel("\(title) settings")
    }
}
