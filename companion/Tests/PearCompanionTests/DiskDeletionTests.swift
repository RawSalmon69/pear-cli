import XCTest
@testable import PearCompanion

/// The safety guard is the whole point of the delete feature: it must refuse
/// everything outside the user's home and every dangerous system location, and
/// only allow paths strictly inside home. These cases pin every refusal listed
/// in the deletion contract against a synthetic home so the test is hermetic.
final class DiskDeletionTests: XCTestCase {
    private let home = "/Users/tester"

    private func refused(_ path: String, _ message: String) {
        XCTAssertFalse(DiskDeletion.canTrash(path: path, home: home), message)
    }

    private func allowed(_ path: String, _ message: String) {
        XCTAssertTrue(DiskDeletion.canTrash(path: path, home: home), message)
    }

    // MARK: Refused

    func testRefusesFilesystemRoot() {
        refused("/", "the filesystem root must never be trashable")
    }

    func testRefusesHomeItself() {
        refused(home, "the home directory itself must not be trashable")
        refused(home + "/", "trailing slash must not smuggle the home dir through")
    }

    func testRefusesAncestorsOfHome() {
        refused("/Users", "an ancestor of home must not be trashable")
    }

    func testRefusesSystemRoots() {
        for root in ["/System", "/Library", "/usr", "/bin", "/sbin",
                     "/private", "/Applications", "/opt"] {
            refused(root, "\(root) must be refused")
            refused(root + "/anything/deep", "a path beneath \(root) must be refused")
        }
    }

    func testRefusesVolumeMountRoot() {
        refused("/Volumes/Backup", "a bare volume mount root must be refused")
        refused("/Volumes/USB Drive", "a mount root with spaces must be refused")
    }

    func testRefusesFewerThanThreeComponents() {
        refused("/etc", "a two-component path must be refused")
        refused("/opt", "a two-component system path must be refused")
    }

    func testRefusesOutsideHome() {
        refused("/Users/someoneelse/Documents/report.pdf",
                "another user's files must be refused")
        refused("/tmp/scratch/file", "a path outside home must be refused")
        refused("/etc/passwd", "a system file must be refused")
    }

    func testRefusesTraversalEscapingHome() {
        refused("/Users/tester/../someoneelse/secrets",
                "`..` escaping home must be refused after standardizing")
    }

    // MARK: Allowed

    func testAllowsPathsStrictlyInsideHome() {
        allowed("/Users/tester/Downloads/big.zip", "a file inside home is trashable")
        allowed("/Users/tester/Library/Caches/foo", "~/Library is inside home, unlike /Library")
        allowed("/Users/tester/Documents/Projects/old", "a nested home dir is trashable")
    }
}
