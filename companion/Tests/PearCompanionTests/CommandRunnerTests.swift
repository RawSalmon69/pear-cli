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
}
