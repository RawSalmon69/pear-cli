import SwiftUI

enum MascotMood {
    case idle
    case excited // unseen note waiting
    case worried // the panel is showing a problem

    func frame(blinking: Bool) -> String {
        switch self {
        case .idle:
            return blinking
                ? " /\\_/\\\n( -.- )\n > ^ <"
                : " /\\_/\\\n( o.o )\n > ^ <"
        case .excited:
            return blinking
                ? " /\\_/\\\n( ^.^ )♪\n > ^ <"
                : " /\\_/\\\n( ^o^ )♪\n > ^ <"
        case .worried:
            return " /\\_/\\\n( o_o );\n > ^ <"
        }
    }
}

/// The same cat that walks across `pear status`, sitting in the panel.
/// Blinks every few seconds; bounces once when excited. With Reduce Motion on
/// it does neither, and the blink loop is never started.
struct MascotView: View {
    let mood: MascotMood

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blinking = false
    @State private var bounce = false

    var body: some View {
        Text(mood.frame(blinking: blinking))
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.accent)
            .lineSpacing(1)
            .fixedSize()
            .multilineTextAlignment(.leading)
            .offset(y: bounce ? -3 : 0)
            // Restarted whenever the mood or Reduce Motion changes: a worried
            // cat never blinks, and with Reduce Motion on the loop never runs.
            .task(id: reduceMotion ? nil : mood) {
                guard !reduceMotion, mood != .worried else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3.5))
                    guard !Task.isCancelled else { return }
                    blinking = true
                    try? await Task.sleep(for: .seconds(0.18))
                    blinking = false
                }
            }
            .onChange(of: mood == .excited) { _, excited in
                guard excited, !reduceMotion else { return }
                withAnimation(Theme.motion(.spring(response: 0.3, dampingFraction: 0.45), reduce: reduceMotion)) { bounce = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(Theme.motion(.spring(response: 0.3, dampingFraction: 0.6), reduce: reduceMotion)) { bounce = false }
                }
            }
            .accessibilityLabel("Pear the cat, \(moodLabel)")
    }

    private var moodLabel: String {
        switch mood {
        case .idle: return "relaxed"
        case .excited: return "New note"
        case .worried: return "worried"
        }
    }
}
