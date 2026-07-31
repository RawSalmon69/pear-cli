import CryptoKit
import XCTest

@testable import PearCompanion

/// The owner signs with `openssl` in a shell script; the app verifies with
/// CryptoKit. Nothing but a round trip proves those two agree on the bytes — the
/// domain prefix, the canonical revocation body, and the sha256 of an order id
/// are all conventions duplicated across a language boundary.
///
/// Every key here is generated into a temporary directory and deleted with it.
final class LicenceScriptRoundTripTests: XCTestCase {
    func testIssueLicenseScriptProducesALicenceTheAppAccepts() throws {
        let owner = try makeOwner()

        let text = try owner.run(
            "issue-license.sh",
            ["buyer@example.com", "ord_roundtrip"]
        ).standardOutput

        let verifier = LicenceVerifier(publicKey: owner.publicKey, appMajor: 3)
        guard case let .valid(licence) = verifier.check(text) else {
            return XCTFail("script-signed licence did not verify: \(verifier.check(text))")
        }
        XCTAssertEqual(licence.email, "buyer@example.com")
        XCTAssertEqual(licence.orderID, "ord_roundtrip")
        XCTAssertEqual(licence.maxMajor, 3)
        XCTAssertEqual(
            licence.issuedAt.timeIntervalSinceNow, 0, accuracy: 300,
            "issuedAt should be now, to the nearest few minutes")
    }

    func testMaxMajorOverrideIsHonoured() throws {
        let owner = try makeOwner()

        let text = try owner.run(
            "issue-license.sh",
            ["buyer@example.com", "ord_future"],
            extraEnvironment: ["PEAR_LICENCE_MAX_MAJOR": "4"]
        ).standardOutput

        let verifier = LicenceVerifier(publicKey: owner.publicKey, appMajor: 5)
        XCTAssertEqual(verifier.check(text), .majorUnsupported(maxMajor: 4, appMajor: 5))
    }

    func testIssueLicenseRefusesWithoutAPrivateKey() throws {
        let owner = try makeOwner(generateKey: false)
        let result = try owner.run("issue-license.sh", ["buyer@example.com", "ord_1"], expectSuccess: false)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.standardError.contains("no signing key"),
            "expected a missing-key refusal, got: \(result.standardError)")
    }

    func testRevokeScriptRefusesWithoutAPrivateKey() throws {
        let owner = try makeOwner(generateKey: false)
        let result = try owner.run("revoke.sh", ["ord_1"], expectSuccess: false)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.standardError.contains("no signing key"),
            "expected a missing-key refusal, got: \(result.standardError)")
    }

    func testKeygenRefusesToOverwriteAnExistingKey() throws {
        let owner = try makeOwner()
        let result = try owner.run("license-keygen.sh", [], expectSuccess: false)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.standardError.contains("Refusing to overwrite"),
            "expected an overwrite refusal, got: \(result.standardError)")
    }

    func testScriptsRefuseAKeyDirectoryInsideAGitWorktree() throws {
        let owner = try makeOwner(generateKey: false)
        // A linked git worktree marks itself with a .git *file*, not a directory.
        let repo = owner.workDir.appendingPathComponent("checkout/keys")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data("gitdir: elsewhere\n".utf8)
            .write(to: owner.workDir.appendingPathComponent("checkout/.git"))

        let result = try owner.run(
            "license-keygen.sh",
            [],
            extraEnvironment: ["PEAR_LICENSING_DIR": repo.path],
            expectSuccess: false
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.standardError.contains("inside the git repository"),
            "expected a git-worktree refusal, got: \(result.standardError)")
    }

    func testRevokeScriptProducesAListTheAppAcceptsAndTrusts() throws {
        let owner = try makeOwner()
        let listURL = owner.workDir.appendingPathComponent("revoked.json")
        let listEnvironment = ["PEAR_REVOKED_JSON": listURL.path]

        // The empty list that ships at launch, so no client 404s.
        try owner.run("revoke.sh", ["--init"], extraEnvironment: listEnvironment)
        let empty = RevocationList.parse(try Data(contentsOf: listURL), publicKey: owner.publicKey)
        XCTAssertEqual(
            RevocationList.decision(list: empty, licenceHash: "whatever", knownSerial: 0),
            .unchanged)
        XCTAssertEqual(try XCTUnwrap(try? empty.get()).serial, 1)
        XCTAssertEqual(try XCTUnwrap(try? empty.get()).revoked, [])

        // …and refunding an order.
        try owner.run("revoke.sh", ["ord_refunded"], extraEnvironment: listEnvironment)
        let load = RevocationList.parse(try Data(contentsOf: listURL), publicKey: owner.publicKey)
        let list = try XCTUnwrap(try? load.get(), "script-signed list did not verify: \(load)")
        XCTAssertEqual(list.serial, 2)

        // The script's sha256 and Swift's must agree, or nothing is ever revoked.
        let hash = Licence.hash(orderID: "ord_refunded")
        XCTAssertEqual(list.revoked, [hash])
        XCTAssertEqual(RevocationList.decision(list: load, licenceHash: hash, knownSerial: 1), .revoked)

        // A different buyer in the same list is untouched.
        XCTAssertEqual(
            RevocationList.decision(
                list: load, licenceHash: Licence.hash(orderID: "ord_kept"), knownSerial: 1),
            .unchanged)
    }

    func testRevokeScriptBumpsTheSerialAndKeepsEarlierEntries() throws {
        let owner = try makeOwner()
        let listURL = owner.workDir.appendingPathComponent("revoked.json")
        let listEnvironment = ["PEAR_REVOKED_JSON": listURL.path]

        try owner.run("revoke.sh", ["--init"], extraEnvironment: listEnvironment)
        try owner.run("revoke.sh", ["ord_one"], extraEnvironment: listEnvironment)
        try owner.run("revoke.sh", ["ord_two"], extraEnvironment: listEnvironment)

        let load = RevocationList.parse(try Data(contentsOf: listURL), publicKey: owner.publicKey)
        let list = try XCTUnwrap(try? load.get(), "re-signed list did not verify: \(load)")
        XCTAssertEqual(list.serial, 3)
        XCTAssertEqual(
            Set(list.revoked),
            Set([Licence.hash(orderID: "ord_one"), Licence.hash(orderID: "ord_two")]))

        // Both are revoked by the one authentic list.
        for order in ["ord_one", "ord_two"] {
            XCTAssertEqual(
                RevocationList.decision(
                    list: load, licenceHash: Licence.hash(orderID: order), knownSerial: 2),
                .revoked, "\(order) should be revoked")
        }

        // Re-running for an order already in the list changes nothing.
        let before = try Data(contentsOf: listURL)
        try owner.run("revoke.sh", ["ord_one"], extraEnvironment: listEnvironment)
        XCTAssertEqual(try Data(contentsOf: listURL), before, "a repeat revoke must be a no-op")
    }

    func testRevokeInitRefusesToReplaceAnExistingList() throws {
        let owner = try makeOwner()
        let listURL = owner.workDir.appendingPathComponent("revoked.json")
        let listEnvironment = ["PEAR_REVOKED_JSON": listURL.path]

        try owner.run("revoke.sh", ["ord_one"], extraEnvironment: listEnvironment)
        let result = try owner.run(
            "revoke.sh", ["--init"], extraEnvironment: listEnvironment, expectSuccess: false)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.standardError.contains("Refusing to replace"),
            "expected an init refusal, got: \(result.standardError)")
    }

    /// The scripts never emit key material, whatever mode they are in.
    func testNoScriptEverPrintsThePrivateKey() throws {
        let owner = try makeOwner()
        let key = try String(contentsOf: owner.privateKeyURL, encoding: .utf8)
        let secretLine = try XCTUnwrap(
            key.split(separator: "\n").first(where: { !$0.hasPrefix("-----") && $0.count > 8 }),
            "expected a PEM body line")

        let listEnvironment = ["PEAR_REVOKED_JSON": owner.workDir.appendingPathComponent("r.json").path]
        var transcripts = [
            try owner.run("license-keygen.sh", ["--public-key"]),
            try owner.run("issue-license.sh", ["buyer@example.com", "ord_x"]),
            try owner.run("revoke.sh", ["ord_x"], extraEnvironment: listEnvironment),
        ]
        transcripts.append(try owner.run("license-keygen.sh", [], expectSuccess: false))

        for transcript in transcripts {
            XCTAssertFalse(transcript.standardOutput.contains(secretLine))
            XCTAssertFalse(transcript.standardError.contains(secretLine))
            XCTAssertFalse(transcript.standardOutput.contains("PRIVATE KEY"))
            XCTAssertFalse(transcript.standardError.contains("PRIVATE KEY"))
        }
    }

    // MARK: - Driving the owner's scripts

    /// A throwaway signing setup: its own key directory, deleted with the test.
    private struct Owner {
        let scriptsDir: URL
        let workDir: URL
        let openssl: String
        let publicKey: Curve25519.Signing.PublicKey

        var privateKeyURL: URL {
            workDir.appendingPathComponent("keys/licence-signing-key.pem")
        }

        @discardableResult
        func run(
            _ script: String,
            _ arguments: [String],
            extraEnvironment: [String: String] = [:],
            expectSuccess: Bool = true,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws -> ScriptResult {
            var environment = ProcessInfo.processInfo.environment
            environment["PEAR_LICENSING_DIR"] = workDir.appendingPathComponent("keys").path
            environment["PEAR_OPENSSL"] = openssl
            for (key, value) in extraEnvironment {
                environment[key] = value
            }

            let process = Process()
            process.executableURL = scriptsDir.appendingPathComponent(script)
            process.arguments = arguments
            process.environment = environment
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            // Drained before waiting: a full pipe would deadlock the child.
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let result = ScriptResult(
                status: process.terminationStatus,
                standardOutput: String(decoding: outData, as: UTF8.self),
                standardError: String(decoding: errData, as: UTF8.self)
            )
            if expectSuccess && result.status != 0 {
                XCTFail("\(script) \(arguments) failed: \(result.standardError)", file: file, line: line)
            }
            return result
        }
    }

    private struct ScriptResult {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    private func makeOwner(generateKey: Bool = true) throws -> Owner {
        let scriptsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PearCompanionTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // companion
            .appendingPathComponent("scripts")
        for script in ["license-common.sh", "license-keygen.sh", "issue-license.sh", "revoke.sh"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: scriptsDir.appendingPathComponent(script).path),
                "missing scripts/\(script)")
        }

        guard let openssl = Self.ed25519OpenSSL() else {
            throw XCTSkip("no Ed25519-capable openssl on this machine (system LibreSSL cannot)")
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pear-licensing-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: workDir) }

        var owner = Owner(
            scriptsDir: scriptsDir,
            workDir: workDir,
            openssl: openssl,
            publicKey: Curve25519.Signing.PrivateKey().publicKey
        )
        guard generateKey else { return owner }

        try owner.run("license-keygen.sh", [])
        let printed = try owner.run("license-keygen.sh", ["--public-key"]).standardOutput
        owner = Owner(
            scriptsDir: scriptsDir,
            workDir: workDir,
            openssl: openssl,
            publicKey: try XCTUnwrap(
                LicenceKey.publicKey(base64: printed),
                "license-keygen.sh --public-key printed something else: \(printed)")
        )
        return owner
    }

    /// The same capability probe the scripts do: LibreSSL, which is
    /// `/usr/bin/openssl` on macOS, cannot do Ed25519 at all.
    private static func ed25519OpenSSL() -> String? {
        let candidates = [
            "/opt/homebrew/opt/openssl@3/bin/openssl",
            "/usr/local/opt/openssl@3/bin/openssl",
            "/opt/homebrew/bin/openssl",
            "/usr/local/bin/openssl",
            "/usr/bin/openssl",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["genpkey", "-algorithm", "ed25519", "-out", "/dev/null"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            process.waitUntilExit()
            if process.terminationStatus == 0 { return path }
        }
        return nil
    }
}
