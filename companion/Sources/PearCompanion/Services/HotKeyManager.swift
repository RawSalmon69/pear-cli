import AppKit
import Carbon.HIToolbox

/// One Carbon event handler for all global hotkeys, dispatching by id so
/// multiple hotkeys (screenshot, OCR) don't each install a handler and
/// double-fire. Register closures; they run on the main actor.
@MainActor
final class HotKeyManager {
    /// Opaque handle returned by `register`; pass to `unregister` to release
    /// both the Carbon hotkey and the stored action.
    struct Token {
        fileprivate let id: UInt32
    }

    static let shared = HotKeyManager()

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1

    private init() {}

    /// `keyCode` is a kVK_* value; `modifiers` an OR of controlKey/shiftKey/etc.
    @discardableResult
    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) -> Token {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1
        actions[id] = action

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            EventHotKeyID(signature: hotKeySignature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        // A failed registration (chord claimed system-wide, bad code) keeps
        // the action out of the table so a later reuse of the Carbon id can't
        // fire the wrong tool; the token stays valid to unregister (no-op).
        if status != noErr || ref == nil {
            actions[id] = nil
        } else if let ref {
            refs[id] = ref
        }
        return Token(id: id)
    }

    func unregister(_ token: Token) {
        if let ref = refs.removeValue(forKey: token.id) {
            UnregisterEventHotKey(ref)
        }
        actions[token.id] = nil
    }

    fileprivate func fire(id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyDispatch,
            1,
            &eventType,
            nil,
            &handler
        )
    }
}

/// Four-char-code 'PEAR' shared by all Pear hotkeys.
private let hotKeySignature: OSType = {
    var code: OSType = 0
    for byte in "PEAR".utf8.prefix(4) {
        code = (code << 8) + OSType(byte)
    }
    return code
}()

/// C callback: pull the hotkey id off the event and dispatch on the main actor.
private let hotKeyDispatch: EventHandlerUPP = { _, event, _ in
    guard let event else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return noErr }
    let id = hotKeyID.id
    Task { @MainActor in HotKeyManager.shared.fire(id: id) }
    return noErr
}
