import XCTest
@testable import PearCompanion

final class CommandRunnerTests: XCTestCase {
    func testSuccessCapturesStdout() async {
        let result = await ProcessRunner().run(binary: "/bin/echo", arguments: ["hi"], timeout: nil)
        guard case .success(let data) = result else { return XCTFail("expected success") }
        XCTAssertEqual(String(data: data, encoding: .utf8), "hi\n")
    }

    func testNonzeroExitFails() async {
        let result = await ProcessRunner().run(binary: "/usr/bin/false", arguments: [], timeout: nil)
        guard case .failed = result else { return XCTFail("expected .failed") }
    }

    func testTimeoutTerminatesOverrunningProcess() async {
        let result = await ProcessRunner().run(binary: "/bin/sleep", arguments: ["5"], timeout: 0.2)
        guard case .timedOut = result else { return XCTFail("expected .timedOut") }
    }

    func testLargeStderrDoesNotDeadlockStdout() async {
        // The child floods stderr well past the ~64 KB pipe buffer, then writes
        // to stdout and exits cleanly. If stderr isn't drained concurrently the
        // child blocks on its stderr write while we block reading stdout, and
        // only the watchdog would break it — so this would time out.
        let script = "yes ================ | head -c 200000 1>&2; echo done"
        let result = await ProcessRunner().run(
            binary: "/bin/sh", arguments: ["-c", script], timeout: 5)
        guard case .success(let data) = result else { return XCTFail("expected .success, got \(result)") }
        XCTAssertEqual(String(data: data, encoding: .utf8), "done\n")
    }
}
