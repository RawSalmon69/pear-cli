import AppIntents
import PearControlChannel
import SwiftUI
import WidgetKit

// Pear's Control Center extension (macOS 26+): one Keep Awake toggle. It owns no
// state; Pear holds the power assertion and publishes it over
// `KeepAwakeChannel`. Pear calls `ControlCenter.reloadControls(ofKind:)` on every
// change, which is what re-reads `currentValue()` after a tap lands.

@available(macOS 26.0, *)
struct SetKeepAwakeIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Keep Awake"
    // Pear's own Toggle Keep Awake action already covers Shortcuts.
    static let isDiscoverable = false

    @Parameter(title: "Keep Awake")
    var value: Bool

    func perform() async throws -> some IntentResult {
        KeepAwakeChannel.live.request(value)
        return .result()
    }
}

@available(macOS 26.0, *)
struct KeepAwakeValue: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        KeepAwakeChannel.live.isOn
    }
}

@available(macOS 26.0, *)
struct KeepAwakeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: KeepAwakeChannel.live.kind, provider: KeepAwakeValue()) { isOn in
            ControlWidgetToggle("Keep Awake", isOn: isOn, action: SetKeepAwakeIntent()) { on in
                Label(on ? "On" : "Off", systemImage: "cup.and.saucer.fill")
            }
        }
        .displayName("Keep Awake")
        .description("Keeps the display awake while Pear is running.")
    }
}

@available(macOS 26.0, *)
@main
struct PearControls: WidgetBundle {
    var body: some Widget {
        KeepAwakeControl()
    }
}
