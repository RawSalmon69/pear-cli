import XCTest

@testable import PearCompanion

/// Resolution of the `pear` CLI the app shells out to. Pear.app ships no copy of
/// its own (the CLI is GPL-3.0), so only installed locations count — and because
/// whatever the user installed is what runs, its version is gated before use.
final class PearBinaryResolutionTests: XCTestCase {

    // MARK: - Path resolution

    func testPrefixInstallWinsOverHomebrew() {
        let found = PearStatsService.pearBinary(isExecutable: { _ in true })
        XCTAssertEqual(found, "/usr/local/bin/pear")
    }

    func testHomebrewCopyUsedWhenOnlyItInstalled() {
        let found = PearStatsService.pearBinary(isExecutable: { path in
            path == "/opt/homebrew/bin/pear"
        })
        XCTAssertEqual(found, "/opt/homebrew/bin/pear")
    }

    func testNoInstalledCopyResolvesNil() {
        XCTAssertNil(PearStatsService.pearBinary(isExecutable: { _ in false }))
    }

    // MARK: - Version parsing

    func testParsesRealVersionOutput() {
        // Leading blank line, version on line 2, more lines after it — the real
        // shape of `pear --version`, not "first token of the first line".
        let output = """

            Pear version 1.47.0
            macOS: 26.2
            Architecture: arm64
            Kernel: 25.2.0
            SIP: Enabled
            Disk Free: 120 GB
            Install: Manual
            Shell: /bin/zsh

            """
        XCTAssertEqual(CLIVersion.parse(output), CLIVersion(major: 1, minor: 47, patch: 0))
    }

    func testParsesNightlyOutputWithCommitHash() {
        // The commit hash sits on the line after the version and must not win.
        let output = "\nPear version 1.47.0\nChannel: Nightly (a1b2c3d)\nmacOS: 26.2\n"
        XCTAssertEqual(CLIVersion.parse(output), CLIVersion(major: 1, minor: 47, patch: 0))
    }

    func testParsesTwoComponentVersionAsPatchZero() {
        XCTAssertEqual(CLIVersion.parse("Pear version 2.0"), CLIVersion(major: 2, minor: 0, patch: 0))
    }

    func testJunkOutputParsesToNil() {
        XCTAssertNil(CLIVersion.parse(""))
        XCTAssertNil(CLIVersion.parse("command not found: pear"))
        // A bare integer or a hash has no dotted numeric token.
        XCTAssertNil(CLIVersion.parse("Pear version 3"))
        XCTAssertNil(CLIVersion.parse("Channel: Nightly (a1b2c3d)"))
    }

    // MARK: - Comparison

    func testComparisonOrdersByComponent() {
        XCTAssertTrue(CLIVersion(major: 1, minor: 45, patch: 0) < CLIVersion(major: 1, minor: 46, patch: 0))
        XCTAssertTrue(CLIVersion(major: 1, minor: 46, patch: 0) < CLIVersion(major: 1, minor: 46, patch: 1))
        XCTAssertTrue(CLIVersion(major: 1, minor: 46, patch: 0) < CLIVersion(major: 2, minor: 0, patch: 0))
        XCTAssertFalse(CLIVersion(major: 1, minor: 46, patch: 0) < CLIVersion(major: 1, minor: 46, patch: 0))
        // 1.9 must not sort above 1.46 — components are numbers, not text.
        XCTAssertTrue(CLIVersion(major: 1, minor: 9, patch: 0) < CLIVersion(major: 1, minor: 46, patch: 0))
    }

    // MARK: - The gate

    func testNoBinaryIsNotInstalled() {
        XCTAssertEqual(PearStatsService.cliStatus(path: nil, versionOutput: nil), .notInstalled)
    }

    func testMinimumVersionIsAccepted() {
        let minimum = PearStatsService.minimumCLIVersion
        let status = PearStatsService.cliStatus(
            path: "/usr/local/bin/pear", versionOutput: "Pear version \(minimum)")
        XCTAssertEqual(status, .ready(path: "/usr/local/bin/pear"))
    }

    func testNewerVersionIsAccepted() {
        let status = PearStatsService.cliStatus(
            path: "/usr/local/bin/pear", versionOutput: "Pear version 99.0.0")
        XCTAssertEqual(status, .ready(path: "/usr/local/bin/pear"))
    }

    func testOlderVersionIsRefusedAndReported() {
        // 1.45.0 is a real released CLI with no `clean --system`.
        let status = PearStatsService.cliStatus(
            path: "/usr/local/bin/pear", versionOutput: "Pear version 1.45.0")
        XCTAssertEqual(status, .tooOld(installed: CLIVersion(major: 1, minor: 45, patch: 0)))
    }

    func testLastReleaseWithoutSystemFlagIsRefused() {
        // V1.46.0 shipped without `clean --system`; the minimum is 1.47.0.
        let status = PearStatsService.cliStatus(
            path: "/usr/local/bin/pear", versionOutput: "\nPear version 1.46.0\nmacOS: 26.2\n")
        XCTAssertEqual(status, .tooOld(installed: CLIVersion(major: 1, minor: 46, patch: 0)))
    }

    func testUnreadableVersionIsRefusedWithoutInventingOne() {
        let status = PearStatsService.cliStatus(
            path: "/usr/local/bin/pear", versionOutput: "usage: pear <command>")
        XCTAssertEqual(status, .tooOld(installed: nil))
        XCTAssertEqual(
            PearStatsService.cliStatus(path: "/usr/local/bin/pear", versionOutput: nil),
            .tooOld(installed: nil))
    }
}
