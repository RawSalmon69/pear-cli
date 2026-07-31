import AppKit
import SwiftUI

/// Empty state for the two features that shell out to the `pear` CLI — the
/// Cleaner panel and the disk bars. Pear.app does not ship the CLI (it is
/// GPL-3.0; this app is paid), so "not installed" is a normal end state, and a
/// CLI older than `PearStatsService.minimumCLIVersion` is refused up front
/// rather than failing mid-run. One line of install command plus a Copy button.
struct CLIRequirementCard: View {
    /// The line the project documents; keep it identical to README/install docs.
    static let installCommand =
        "curl -fsSL https://raw.githubusercontent.com/RawSalmon69/pear-cli/main/install.sh | bash"

    let status: PearCLI

    @State private var copied = false

    private var headline: String {
        if case .tooOld = status { return "Pear CLI is out of date" }
        return "Pear CLI not installed"
    }

    private var detail: String? {
        guard case .tooOld(let installed) = status else { return nil }
        let have = installed.map { "\($0) is installed" } ?? "The installed version is unreadable"
        return "\(have); Pear needs \(PearStatsService.minimumCLIVersion) or newer. "
            + "Re-run the install command to update."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(headline, systemImage: "terminal")
                .font(Theme.emphasis)
            if let detail {
                Text(detail)
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text(Self.installCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.installCommand, forType: .string)
                    copied = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .focusable(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.heroPadding)
        .glassCard(cornerRadius: 16)
    }
}
