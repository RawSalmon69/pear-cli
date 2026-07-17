// Adapted from Loop (GPL-3.0), https://github.com/MrKai77/Loop
//
// Loop consumes ring-navigation keys through a CGEvent tap so they never
// reach the frontmost app. This is the same, scoped as tightly as possible:
// the tap exists ONLY between trigger-down and release (created in
// `activate()`, invalidated in `teardown()`), listens ONLY to keyDown, and
// swallows ONLY the keys the ring actually handles (arrows + Escape).
// Everything else passes through untouched. Requires the same Accessibility
// permission the AX engine already holds; the ring never activates untrusted.

import AppKit
import CoreGraphics

/// A key event tap that lets `handler` decide per-event whether to swallow.
/// Lives on the main run loop, so the callback runs on the main thread and can
/// safely touch main-actor state via `assumeIsolated`.
///
/// `eventMask` defaults to keyDown-only, preserving the original behavior for
/// the ring/switcher call sites; Clean Mode passes keyDown+keyUp+flagsChanged
/// to swallow every keystroke while the screen is blanked. The mask alone
/// decides which types reach `handler` — mouse events are never in any mask, so
/// the pointer always stays live.
@MainActor
final class KeySwallowTap {
    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Returns true to swallow the event, false to pass it through.
    private let handler: (NSEvent) -> Bool

    /// nil when the tap can't be created (TCC denied mid-session, sandbox);
    /// callers fall back to read-only monitors (or, for Clean Mode, to leaving
    /// the keyboard fully live).
    init?(
        eventMask: CGEventMask = 1 << CGEventType.keyDown.rawValue,
        handler: @escaping (NSEvent) -> Bool
    ) {
        self.handler = handler

        let mask = eventMask
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, cgEvent, refcon in
                guard let refcon else { return Unmanaged.passUnretained(cgEvent) }
                let tap = Unmanaged<KeySwallowTap>.fromOpaque(refcon).takeUnretainedValue()
                // assumeIsolated is safe (the source is on the main run loop)
                // but its return type must be Sendable, which Unmanaged<CGEvent>
                // is not — so return the swallow decision and wrap outside.
                let swallow = MainActor.assumeIsolated {
                    tap.shouldSwallow(type: type, cgEvent: cgEvent)
                }
                return swallow ? nil : Unmanaged.passUnretained(cgEvent)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return nil
        }

        machPort = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func invalidate() {
        if let machPort { CGEvent.tapEnable(tap: machPort, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let machPort { CFMachPortInvalidate(machPort) }
        runLoopSource = nil
        machPort = nil
    }

    /// Safety net: the callback holds `self` unretained, so a tap dropped
    /// WITHOUT invalidate() would dangle on the next event. Every current
    /// owner invalidates explicitly; this covers the future one that forgets.
    /// (Owners are all main-actor, so deallocation happens on the main thread.)
    deinit {
        MainActor.assumeIsolated { invalidate() }
    }

    private func shouldSwallow(type: CGEventType, cgEvent: CGEvent) -> Bool {
        // The system disables a tap that stalls; re-enable and pass through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let machPort { CGEvent.tapEnable(tap: machPort, enable: true) }
            return false
        }
        // Any type the mask delivered (keyDown by default; also keyUp and
        // flagsChanged when the caller asked for them) is handed to `handler`.
        guard let event = NSEvent(cgEvent: cgEvent) else {
            return false
        }
        return handler(event)
    }
}
