import SwiftUI
import AppKit

/// Floating progress panel for clean/optimize runs: live transcript,
/// Cancel while running, Done when finished. One panel; starting a new run
/// while one is live just brings it forward.
@MainActor
final class CleanerWindowController {
    private var panel: NSPanel?
    let runner = CleanerRunner()

    func run(command: String) {
        if runner.isRunning {
            panel?.makeKeyAndOrderFront(nil)
            return
        }
        runner.run(command: command)
        show()
    }

    private func show() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let view = CleanerProgressView(
            runner: runner,
            onClose: { [weak self] in self?.hide() }
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    private func hide() {
        panel?.orderOut(nil)
    }
}

private struct CleanerProgressView: View {
    let runner: CleanerRunner
    let onClose: () -> Void

    private var title: String {
        switch runner.phase {
        case .idle: return "Pear"
        case .running(let command): return command == "clean" ? "Cleaning…" : "Optimizing…"
        case .finished(let command, let code):
            let verb = command == "clean" ? "Clean" : "Optimize"
            return code == 0 ? "\(verb) finished" : "\(verb) stopped"
        case .unavailable: return "pear CLI not found"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            HStack(spacing: 8) {
                if runner.isRunning {
                    ProgressView().controlSize(.small)
                }
                Text(title).font(Theme.title)
                Spacer()
            }

            if case .unavailable = runner.phase {
                Text("Install the pear CLI to run cleanup from here.")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
            } else {
                TranscriptView(text: runner.transcript)
            }

            HStack {
                Spacer()
                if runner.isRunning {
                    Button("Cancel") { runner.cancel() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Done") { onClose() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 460, height: 340)
    }
}

/// Auto-scrolling monospaced transcript.
private struct TranscriptView: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "Starting…" : text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
                    .id("tail")
            }
            .glassCard(cornerRadius: 10)
            .onChange(of: text) {
                proxy.scrollTo("tail", anchor: .bottom)
            }
        }
    }
}
