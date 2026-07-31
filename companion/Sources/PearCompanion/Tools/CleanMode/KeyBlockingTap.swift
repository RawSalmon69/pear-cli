import CoreFoundation
import CoreGraphics

/// The state the C tap callback needs, reachable through its `refcon`. The
/// callback holds this object *unretained*: `KeyBlockingTap` owns the only
/// strong reference and always tears the tap down before releasing it, so the
/// callback can never be handed a dead pointer.
private final class TapContext: @unchecked Sendable {
    let handler: (CGEvent) -> Bool
    var port: CFMachPort?
    var source: CFRunLoopSource?
    private var isTornDown = false

    init(handler: @escaping (CGEvent) -> Bool) {
        self.handler = handler
    }

    /// Re-arms a tap the system switched off. macOS disables a tap whose
    /// callback ran too long (`.tapDisabledByTimeout`) or when the user forces
    /// input through (`.tapDisabledByUserInput`). A keyboard lock that quietly
    /// stops locking halfway is worse than one that never engaged, so both cases
    /// re-enable rather than going dead.
    func reEnable() {
        guard !isTornDown, let port else { return }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// Idempotent teardown: disable the tap, unhook it from the run loop, drop
    /// the CF objects. A no-op when nothing was ever wired up.
    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        port = nil
        source = nil
    }
}

/// C entry point for the tap. A `@convention(c)` function captures nothing, so
/// everything it needs arrives as the `refcon`.
private func keyBlockingTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<TapContext>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        context.reEnable()
        return Unmanaged.passUnretained(event)
    }

    // true swallows the event, false passes it through untouched.
    return context.handler(event) ? nil : Unmanaged.passUnretained(event)
}

/// A session-level keyboard event tap: `handler` sees every event matching
/// `eventMask` and returns true to swallow it, false to let it through.
///
/// The tap is session-scoped, so the OS destroys it the instant this process
/// ends — a tap can never outlive Pear. `init` fails when the tap cannot be
/// created, almost always because Accessibility permission has not been
/// granted, which lets callers fall back to leaving input fully live.
@MainActor
final class KeyBlockingTap {
    private let context: TapContext

    init?(eventMask: CGEventMask, handler: @escaping (CGEvent) -> Bool) {
        context = TapContext(handler: handler)
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: keyBlockingTapCallback,
                userInfo: Unmanaged.passUnretained(context).toOpaque()),
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        else { return nil }

        context.port = port
        context.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// Stops swallowing and releases the tap. Safe to call twice, and safe when
    /// no event ever arrived.
    func invalidate() {
        context.tearDown()
    }

    /// Backstop: dropping the last reference without calling `invalidate()` must
    /// still unhook the tap, or a forgotten tap keeps eating keystrokes.
    deinit {
        context.tearDown()
    }
}
