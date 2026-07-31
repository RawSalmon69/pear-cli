import SwiftUI

/// The licence pane: what state this Mac is in, somewhere to put a licence
/// (pasted or dropped), and a way to take it off again.
///
/// It shows the buyer's email on purpose. There is no device limit and no
/// activation server, so the name on the licence is the only social friction in
/// the whole design — hiding it would remove the one thing that makes handing a
/// key around feel like something.
struct LicenceSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var pasted = ""
    /// The outcome of the last attempt, and the exact text it was made from. The
    /// status line shows only while the field still holds that text, so editing
    /// after a rejection hides the stale message without writing any state per
    /// keystroke — nothing to dedupe because nothing is written.
    @State private var lastCheck: LicenceCheck?
    @State private var checkedText = ""
    @State private var targeted = false

    /// Shown once a licence is accepted. Tools are registered once, at launch,
    /// so they genuinely do not come back until Pear is reopened. Saying so is
    /// the honest thing, and it is what the couple key in this same popover
    /// already does.
    static let activatedMessage =
        "Licence verified — thank you. Quit and reopen Pear to bring the tools back."

    /// The line under the field after an attempt. Pure, so the mapping is
    /// testable: a rejected licence must surface the rejecting check's *own*
    /// wording, never a generic "invalid key" of ours.
    static func status(after check: LicenceCheck) -> String {
        if case .valid = check { return activatedMessage }
        return check.message
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            currentState
            entrySection
            if case .licensed = env.entitlement.entitlement { removalSection }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The whole pane is the drop target, not a small well inside it: a
        // licence file is the thing the buyer has in their hand, and hunting for
        // a rectangle to aim at is the part people get wrong.
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .opacity(targeted ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: targeted)
                .allowsHitTesting(false)
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted, perform: handleDrop)
    }

    // MARK: - Current state

    @ViewBuilder private var currentState: some View {
        switch env.entitlement.entitlement {
        case .licensed(let email):
            VStack(alignment: .leading, spacing: Theme.itemGap) {
                SectionLabel(text: "Licence")
                Label("Licensed to \(email)", systemImage: "checkmark.seal.fill")
                    .font(Theme.emphasis)
                    .foregroundStyle(Theme.accent)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Every Pear 3.x update is included. Nothing expires and nothing checks in — "
                    + "Pear keeps working offline.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .trial(let daysRemaining):
            VStack(alignment: .leading, spacing: Theme.itemGap) {
                SectionLabel(text: "Trial")
                Label(LockedCopy.trialStatus(daysRemaining: daysRemaining), systemImage: "hourglass")
                    .font(Theme.emphasis)
                Text("Every feature is on, with no account and no card. When the fourteen days are "
                    + "up the tools pause; your scratchpad notes and shelf items stay.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                buyLink
            }
        case .expired(let reason):
            let copy = LockedCopy.of(reason)
            VStack(alignment: .leading, spacing: Theme.itemGap) {
                SectionLabel(text: "Licence")
                Label(copy.headline, systemImage: copy.symbol)
                    .font(Theme.emphasis)
                Text(copy.detail)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(copy.price)
                    .font(Theme.caption)
                    .fixedSize(horizontal: false, vertical: true)
                buyLink
            }
        }
    }

    private var buyLink: some View {
        Link("Buy a licence", destination: LockedCopy.pricingURL)
            .font(Theme.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Theme.accent)
    }

    // MARK: - Entering one

    private var entrySection: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Enter a licence")
            Text("Paste the key from your receipt, or drop the "
                + ".\(LicenceVerifier.fileExtension) file anywhere in this pane.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Licence key", text: $pasted, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...5)
                .font(.system(size: 10, design: .monospaced))

            HStack(spacing: 6) {
                Button("Activate") { submit(pasted) }
                    .font(Theme.caption)
                    .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer(minLength: 0)
            }

            if let attempt {
                Text(attempt.text)
                    .font(Theme.caption)
                    .foregroundStyle(attempt.accepted ? Theme.accent : Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The last attempt's message and its colour, or nil when the field no longer
    /// holds the text that was checked.
    private var attempt: (text: String, accepted: Bool)? {
        guard let lastCheck, pasted == checkedText else { return nil }
        if case .valid = lastCheck { return (Self.activatedMessage, true) }
        return (Self.status(after: lastCheck), false)
    }

    /// Runs the text past the store, which keeps it only if it genuinely
    /// verifies. A rejected licence is left in the field on purpose — a truncated
    /// blob needs fixing, not retyping from scratch — which is also how a dropped
    /// file's contents become visible and editable.
    private func submit(_ text: String) {
        let check = env.entitlement.activate(text)
        lastCheck = check
        if case .valid = check {
            pasted = ""
            checkedText = ""
        } else {
            if pasted != text { pasted = text }
            checkedText = text
        }
    }

    // MARK: - Dropping one

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in accept(url) }
            }
        }
        return handled
    }

    /// A dropped file lands in the field and is then checked, so the same
    /// rejection wording, and the same fixable text, comes back for a bad file as
    /// for a bad paste. Anything that is not a licence file is refused before it
    /// is read — the extension is the only reason to open a stranger's file — and
    /// a refusal never wipes out what the user had already typed.
    @MainActor private func accept(_ url: URL) {
        guard
            url.pathExtension.lowercased() == LicenceVerifier.fileExtension,
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            checkedText = pasted
            lastCheck = .malformed
            return
        }
        submit(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Removing one

    private var removalSection: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Remove")
            Text("Deletes the licence file from this Mac. Pear goes back to the trial, or locks if "
                + "the trial has already ended. Your key itself keeps working — you can paste it "
                + "back any time, here or on another Mac.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Remove licence from this Mac") { env.entitlement.removeLicence() }
                .font(Theme.caption)
        }
    }
}
