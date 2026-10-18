import PearControlChannel
import XCTest

/// The Darwin-notification channel the Control Center control speaks. Each test
/// uses its own prefix, so a running Pear's names are never posted or read.
final class KeepAwakeChannelTests: XCTestCase {
    private func makeChannel() -> KeepAwakeChannel {
        KeepAwakeChannel(prefix: "com.rawsalmon69.pear.tests.\(UUID().uuidString)")
    }

    func testReadsOffWithNoHost() {
        XCTAssertFalse(makeChannel().isOn)
    }

    func testPublishedStateIsReadBack() {
        let channel = makeChannel()
        let host = KeepAwakeChannelHost(channel: channel) { _ in }
        host.publish(true)
        XCTAssertTrue(channel.isOn)
        host.publish(false)
        XCTAssertFalse(channel.isOn)
    }

    /// A Pear that quits, crashes or turns Switches off must not leave the
    /// control reading on.
    func testStateClearsWhenHostGoes() {
        let channel = makeChannel()
        var host: KeepAwakeChannelHost? = KeepAwakeChannelHost(channel: channel) { _ in }
        host?.publish(true)
        host = nil
        XCTAssertFalse(channel.isOn)
    }

    func testRequestsReachHost() {
        let channel = makeChannel()
        let on = expectation(description: "on")
        let off = expectation(description: "off")
        let host = KeepAwakeChannelHost(channel: channel) { value in
            (value ? on : off).fulfill()
        }
        channel.request(true)
        channel.request(false)
        wait(for: [on, off], timeout: 2)
        withExtendedLifetime(host) {}
    }
}
