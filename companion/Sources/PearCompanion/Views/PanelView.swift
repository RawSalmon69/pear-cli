import SwiftUI

/// Panel layout in spec order. Every section is a stub the feature passes
/// replace; the skeleton only fixes structure and width.
struct PanelView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderSection()
            MessagesSection()
            ShelfSection()
            StatsSection()
            ActionsSection()
            FooterSection()
        }
        .padding(14)
        .frame(width: 360)
    }
}

struct HeaderSection: View {
    var body: some View {
        HStack {
            Text("🍐")
                .font(.largeTitle)
            Text("Pear")
                .font(.system(.title2, design: .rounded).weight(.semibold))
            Spacer()
        }
    }
}

struct MessagesSection: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("Notes")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
            Text("No notes yet")
                .frame(maxWidth: .infinity, minHeight: 60)
        }
        .padding(10)
        .glassCard()
    }
}

struct ShelfSection: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("Shelf")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Drop a file to share it")
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .padding(10)
        .glassCard()
    }
}

struct StatsSection: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        HStack(spacing: 8) {
            ForEach(env.stats.current(), id: \.label) { stat in
                VStack {
                    Image(systemName: stat.symbol)
                    Text(stat.value)
                        .font(.system(.callout, design: .rounded).weight(.medium))
                    Text(stat.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(8)
                .glassCard(cornerRadius: 10)
            }
        }
    }
}

struct ActionsSection: View {
    var body: some View {
        HStack {
            Button("Clean Now") {}
            Button("Optimize") {}
        }
        .buttonStyle(.bordered)
    }
}

struct FooterSection: View {
    var body: some View {
        HStack {
            Text("Pear \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }
}
