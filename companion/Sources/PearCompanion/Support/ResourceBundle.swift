import Foundation

/// The SPM resource bundle, resolved explicitly rather than through
/// `Bundle.module`. The generated `Bundle.module` accessor varies by
/// toolchain: the one older SwiftPMs emit looks only next to
/// `Bundle.main.bundleURL` (the .app root) and in the original build
/// directory — never in `Contents/Resources`, where build.sh installs the
/// bundle — and `fatalError`s when both miss. CI's default Xcode built
/// companion-v2.2.0 that way and the shipped app crashed at launch, while
/// local builds (newer accessor) ran fine. Resolving the known app-bundle
/// location first, then falling back to `Bundle.module` for `swift run` and
/// tests, behaves the same on every toolchain.
extension Bundle {
    static let pearResources: Bundle = {
        let name = "PearCompanion_PearCompanion.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()
}
