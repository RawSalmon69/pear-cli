/// Compile-time feature switches.
enum FeatureFlags {
    /// The couple-note pipe (notes, poke, seen receipts, CloudKit sync and
    /// its remote-notification wiring). Hidden for the general product;
    /// the files stay for a future sync tier.
    static let coupleNote = false
}
