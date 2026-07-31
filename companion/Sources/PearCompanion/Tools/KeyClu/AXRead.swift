import ApplicationServices

/// Typed reads over the Accessibility API. Every getter returns nil when the
/// attribute is missing, unreadable, or not the type asked for, so callers can
/// walk a foreign app's UI with `??` defaults instead of error handling.
enum AXRead {
    /// Every AX read is synchronous IPC into the target app, and the system
    /// default timeout is 6 seconds per read. Walking a whole menu tree against
    /// a beachballing app at that rate freezes our main thread for minutes, so
    /// each element is capped at 250ms: orders of magnitude more than a healthy
    /// app needs to answer one attribute read, and a blink if the app is gone.
    static func capTimeout(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, 0.25)
    }

    /// The raw attribute value, or nil for any non-success result. CF values
    /// come back bridged, so a `CFNumber` survives as something `as? Int`
    /// accepts and a `CFBoolean` as something `as? Bool` accepts.
    static func value(_ element: AXUIElement, _ attribute: String) -> Any? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else {
            return nil
        }
        return raw
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        value(element, attribute) as? Bool
    }

    /// `as?` is not available for CoreFoundation types, so the type is checked
    /// by CFTypeID before the cast.
    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = value(element, attribute),
            CFGetTypeID(raw as CFTypeRef) == AXUIElementGetTypeID()
        else { return nil }
        return (raw as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        value(element, attribute) as? [AXUIElement]
    }
}
