// Adapted from DockDoor (GPL-3.0), https://github.com/ejbills/DockDoor,
// commit 78b0862f — original: DockDoor/Extensions/AXUIElement.swift.
//
// A minimal, main-actor-only set of AX read helpers (DockDoor's file threads
// AX reads through DispatchQueue.main.sync for cross-process elements; every
// call site here is already on the main actor, so the reads are direct). No
// private APIs, no _AXUIElementGetWindow.

import ApplicationServices

/// Small typed AX attribute reads shared by the Dock observer and the window
/// enumerator. All calls must run on the main actor.
@MainActor
enum DockAX {
    /// Cap the ~6 s default AX messaging timeout on an element we create, so a
    /// beachballing target app can never freeze our main thread. 0.15 s: these
    /// reads are synchronous on the main actor and a hover can issue dozens
    /// (per pid, per window), so the per-call cap must be small enough that
    /// even the worst case stays inside `DockWindows.enumerationBudget` —
    /// 0.5 s per call let a few unresponsive helper pids stack into
    /// multi-second beachballs per hover.
    static func capTimeout(_ element: AXUIElement, _ seconds: Float = 0.15) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        value(element, attribute) as? [AXUIElement]
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((raw as! CFBoolean))
    }

    static func url(_ element: AXUIElement, _ attribute: String) -> URL? {
        value(element, attribute) as? URL
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(raw as! AXValue, .cgSize, &size) ? size : nil
    }
}
