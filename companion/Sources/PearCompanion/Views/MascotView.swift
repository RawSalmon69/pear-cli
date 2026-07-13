import SwiftUI

enum MascotMood {
    case idle
    case excited // unseen note waiting
    case worried // disk nearly full

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
/// Blinks every few seconds; bounces once when excited.
struct MascotView: View {
    let mood: MascotMood

    @State private var blinking = false
    @State private var bounce = false

    private let blinkTimer = Timer.publish(every: 3.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(mood.frame(blinking: blinking))
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.accent)
            .lineSpacing(1)
            .fixedSize()
            .multilineTextAlignment(.leading)
            .offset(y: bounce ? -3 : 0)
            .onReceive(blinkTimer) { _ in
                guard mood != .worried else { return }
                blinking = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { blinking = false }
            }
            .onChange(of: mood == .excited) { excited in
                guard excited else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.45)) { bounce = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { bounce = false }
                }
            }
            .accessibilityLabel("Pear the cat, \(moodLabel)")
    }

    private var moodLabel: String {
        switch mood {
        case .idle: return "relaxed"
        case .excited: return "excited — new note"
        case .worried: return "worried — disk almost full"
        }
    }
}

/// Time-of-day greeting for the header.
func greeting(now: Date = Date(), role: String) -> String {
    let name = role.lowercased() == "pear" ? "Pear 🍐" : "raws"
    switch Calendar.current.component(.hour, from: now) {
    case 5..<12: return "Good morning, \(name)"
    case 12..<17: return "Good afternoon, \(name)"
    case 17..<22: return "Good evening, \(name)"
    default: return "Up late, \(name)?"
    }
}
