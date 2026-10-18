import PearControlChannel
import SwiftUI
import WidgetKit

/// Quick system toggles in a grid: Keep Awake, Lid Closed, Screen Saver, Lock Screen,
/// Hide Desktop, Show Hidden, Big Cursor. The tile only opens the grid;
/// individual switches act only on a user tap, so the tool is safe to enable
/// by default. `stop()` releases any held power assertion.
@MainActor
final class SwitchesTool: Tool {
    static let toolID = "switches"

    let id = SwitchesTool.toolID
    let title = "Switches"
    let icon = "switch.2"
    let category = ToolCategory.system
    let summary = "System toggles: keep awake, lock the screen, hide the desktop."
    let hotkey: HotKeyChord? = nil

    private let model = SwitchesModel()

    var acceptsHotkey: Bool { false }

    /// How many toggles are on, as last read. Keep Awake is always current
    /// (Pear holds the assertion); the rest are as fresh as the popover's last
    /// `refresh()` — no process is spawned just to label a row.
    var status: String? {
        let on = [model.keepAwakeOn, model.lidClosedOn, model.hideDesktopOn, model.showHiddenOn]
            .filter { $0 }.count
        return on > 0 ? "\(on) on" : nil
    }

    var entry: ToolEntry {
        .popover { [model] in AnyView(SwitchesView(model: model)) }
    }

    /// The Toggle Keep Awake action, the same switch the grid's tile flips.
    /// Returns the new state.
    func toggleKeepAwake() -> Bool {
        model.setKeepAwake(!model.keepAwakeOn)
        return model.keepAwakeOn
    }

    /// macOS 26+: serves the Control Center Keep Awake control. Its taps arrive
    /// as requests and go through `setKeepAwake`, like a grid tap, and every
    /// change (from any surface) is published back and the control reloaded.
    /// While the tool is off nothing listens and the state reads off, so the
    /// control cannot turn Keep Awake on.
    func start() {
        guard #available(macOS 26, *), !SwitchTestGuard.isRunningTests else { return }
        let host = KeepAwakeChannelHost(channel: .live) { [weak self] on in
            MainActor.assumeIsolated { self?.model.setKeepAwake(on) }
        }
        // The hook owns the host: clearing it in `stop()` cancels every token.
        model.onKeepAwakeChange = { on in
            host.publish(on)
            ControlCenter.shared.reloadControls(ofKind: KeepAwakeChannel.live.kind)
        }
        model.onKeepAwakeChange?(model.keepAwakeOn)
    }

    func stop() {
        model.teardown()
        model.onKeepAwakeChange = nil
    }
}
