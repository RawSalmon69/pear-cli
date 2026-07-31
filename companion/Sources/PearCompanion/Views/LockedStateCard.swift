import SwiftUI

/// Every word the app says about being locked or running out of trial, in one
/// table. The locked card and the settings pane both read it, so the two
/// surfaces cannot drift apart, and the copy can be reviewed — and tested — as
/// writing rather than as code.
///
/// Tone rule for anything added here: state the situation, the price, and the
/// two ways forward. No countdown, no "act now", no guilt. This is the screen a
/// person is looking at while deciding whether Pear was worth paying for.
struct LockedCopy: Equatable, Sendable {
    /// What happened, in one line.
    let headline: String
    /// The same thing calmly, plus the way out.
    let detail: String
    /// What it costs. Deliberately not one sentence for every reason: someone
    /// who already bought Pear once must not be quoted the new-buyer price.
    let price: String
    /// Leading glyph. A padlock would be the obvious pick and the wrong one —
    /// nothing here is a security failure, so each reason gets the symbol for
    /// what actually happened.
    let symbol: String

    static let pricingURL = URL(string: "https://pear.phanthawas.dev/pricing")!

    /// Where a refunded buyer writes. Same address the site's refund policy and
    /// privacy page give.
    static let supportEmail = "contact@phanthawas.dev"

    /// Said last and quietly on both surfaces. `site/terms.html` §2 promises in
    /// writing that content the user created "remains accessible and
    /// exportable", so the locked state has to say so out loud — and
    /// `Tool.survivesExpiry` has to keep it true.
    static let contentPromise =
        "Scratchpad and Shelf keep working. Your notes and shelf items stay open and exportable."

    static func of(_ reason: ExpiryReason) -> LockedCopy {
        switch reason {
        case .trialEnded:
            return LockedCopy(
                headline: "The trial has ended",
                detail: "Pear ran with everything switched on for fourteen days. "
                    + "The tools are paused now, and a licence turns them back on.",
                price: "$19, once, for every Pear 3.x update, on any Mac you own. No subscription.",
                symbol: "hourglass")
        case .licenceRefunded:
            return LockedCopy(
                // Verbatim `RevocationList.refundedMessage`. A refund is what
                // actually happened; a generic error here reads as a bug in Pear
                // to someone who just got their money back.
                headline: RevocationList.refundedMessage,
                detail: "The order behind this licence was refunded, so it no longer unlocks the "
                    + "tools. If that is a surprise, write to \(supportEmail) and we will sort it out.",
                price: "A new licence is $19, once.",
                symbol: "arrow.uturn.backward")
        case .licenceForOlderMajor(let maxMajor):
            return LockedCopy(
                headline: "Your licence covers Pear \(maxMajor)",
                detail: "Nothing is wrong with it. This is a newer major version, which is a "
                    + "separate purchase, discounted for people who already own Pear \(maxMajor). "
                    + "Your Pear \(maxMajor) install keeps working.",
                price: "Existing owners upgrade at a discount.",
                symbol: "arrow.up.circle")
        }
    }

    /// How the trial reads wherever it is stated outright — the settings pane,
    /// whose job is to show the current state.
    static func trialStatus(daysRemaining: Int) -> String {
        daysRemaining <= 1 ? "Last day of your trial" : "\(daysRemaining) days left in your trial"
    }

    /// The trial's last few days, for the one quiet line in the panel. Nil while
    /// there is still time: there is nothing useful to tell someone on day two,
    /// and a line that is always there is a line nobody reads.
    static func trialNotice(daysRemaining: Int) -> String? {
        guard daysRemaining <= noticeDays else { return nil }
        return trialStatus(daysRemaining: daysRemaining) + "."
    }

    /// How near the end the panel starts mentioning the trial at all.
    static let noticeDays = 3
}

/// The locked state: one card where twenty tool tiles were.
///
/// It sits above the Tools grid rather than deleting it, because two tools
/// survive expiry and their tiles are the user's way back to their own writing.
/// Removing those tiles to make the card look tidier would break the promise the
/// card's last line makes.
struct LockedStateCard: View {
    let reason: ExpiryReason

    @State private var showLicence = false

    private var copy: LockedCopy { LockedCopy.of(reason) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            Label(copy.headline, systemImage: copy.symbol)
                .font(Theme.emphasis)

            Text(copy.detail)
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(copy.price)
                .font(Theme.body)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.itemGap) {
                Link("Buy a licence", destination: LockedCopy.pricingURL)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                Button("I have a licence") { showLicence = true }
                    .buttonStyle(.bordered)
                    .popover(isPresented: $showLicence) { SettingsPopover(tab: .licence) }
            }
            .font(Theme.body)
            .controlSize(.regular)
            .focusable(false)

            Text(LockedCopy.contentPromise)
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.heroPadding)
        .glassCard(cornerRadius: 16)
    }
}
