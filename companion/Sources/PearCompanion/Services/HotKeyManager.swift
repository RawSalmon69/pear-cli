import AppKit
import Carbon.HIToolbox

/// One Carbon event handler for all global hotkeys, dispatching by id so
/// multiple hotkeys (screenshot, OCR) don't each install a handler and
/// double-fire. Register closures; they run on the main actor.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1

    private init() {}

    /// `keyCode` is a kVK_* value; `modifiers` an OR of controlKey/shiftKey/etc.
    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1
        actions[id] = action

        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            EventHotKeyID(signature: hotKeySignature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if let ref { refs.append(ref) }
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
