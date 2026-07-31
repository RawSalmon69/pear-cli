/// Compile-time feature switches.
enum FeatureFlags {
    /// The couple-note pipe (notes, poke, seen receipts, CloudKit sync and
    /// its remote-notification wiring). Hidden for the general product;
    /// the files stay for a future sync tier.
    static let coupleNote = false

    /// The paywall: whether an expired trial actually locks the paid tools.
    ///
    /// **Off until two things are true**, both of which would otherwise brick the
    /// app for real people:
    ///
    /// 1. `LicenceKey.publicKeyBase64` is the owner's real key, not the committed
    ///    placeholder. Against the placeholder every licence fails to verify, so
    ///    turning this on would lock every user out after 14 days with no way to
    ///    buy their way back in.
    /// 2. Existing friends-and-family installs have been issued licences. The
    ///    bundle ID has never changed, so they auto-update through the same
    ///    appcast — flipping this before they hold a licence pushes a paywall at
    ///    people who were given the app.
    ///
    /// The licensing code itself is live regardless: the trial clock runs, a
    /// licence can be entered and verified, and the settings pane shows real
    /// state. Only the *lock* waits on this.
    static let paywall = false
}
