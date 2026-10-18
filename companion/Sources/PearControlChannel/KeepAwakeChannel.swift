import Foundation
import notify

/// Darwin-notification channel between Pear and its Control Center extension
/// (macOS 26+). The sandboxed extension cannot reach Pear's power assertion, so
/// it posts a request and Pear does the work. No app-group container: a
/// non-sandboxed app touching one may prompt on macOS 15+.
///
/// Pear publishes Keep Awake's state as the notify state of `stateName`, held by
/// a token Pear keeps open. notifyd drops a name's state when its last token
/// goes, so a Pear that quit, crashed, or has Switches turned off reads as off.
public struct KeepAwakeChannel: Sendable {
    public static let live = KeepAwakeChannel(prefix: "com.rawsalmon69.pear.keepawake")

    /// Also the ControlWidget kind, so both ends name the control the same way.
    public let kind: String
    let stateName: String
    let requestOnName: String
    let requestOffName: String

    /// Tests pass a unique prefix so they never touch a running Pear's names.
    public init(prefix: String) {
        kind = prefix
        stateName = prefix + ".state"
        requestOnName = prefix + ".request.on"
        requestOffName = prefix + ".request.off"
    }

    /// Extension end: asks Pear to turn Keep Awake on or off. Nobody hears it
    /// when Pear is not running, and the control then reads `isOn` (off) again.
    public func request(_ on: Bool) {
        notify_post(on ? requestOnName : requestOffName)
    }

    /// Extension end: Keep Awake as Pear last published it.
    public var isOn: Bool {
        var token: Int32 = 0
        guard notify_register_check(stateName, &token) == NOTIFY_STATUS_OK else { return false }
        defer { notify_cancel(token) }
        var state: UInt64 = 0
        notify_get_state(token, &state)
        return state == 1
    }
}

/// Pear's end: hears the extension's requests on the main queue and publishes
/// state. Lives exactly as long as the Switches tool is on; dropping it cancels
/// every token, which also clears the published state to off.
public final class KeepAwakeChannelHost {
    private let channel: KeepAwakeChannel
    private var stateToken: Int32 = 0
    private var requestTokens: [Int32] = []

    public init(channel: KeepAwakeChannel, onRequest: @escaping (Bool) -> Void) {
        self.channel = channel
        notify_register_check(channel.stateName, &stateToken)
        for (name, on) in [(channel.requestOnName, true), (channel.requestOffName, false)] {
            var token: Int32 = 0
            if notify_register_dispatch(name, &token, .main, { _ in onRequest(on) }) == NOTIFY_STATUS_OK {
                requestTokens.append(token)
            }
        }
    }

    public func publish(_ on: Bool) {
        notify_set_state(stateToken, on ? 1 : 0)
        notify_post(channel.stateName)
    }

    deinit {
        notify_cancel(stateToken)
        requestTokens.forEach { notify_cancel($0) }
    }
}
