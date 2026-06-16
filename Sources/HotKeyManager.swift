import AppKit
import Carbon.HIToolbox

// System-wide hotkeys via the Carbon Hot Key API. This works without
// Accessibility permission (unlike an NSEvent global key monitor), which keeps
// the screenshot path usable even before the user grants Accessibility.
final class HotKeyManager {
    static let shared = HotKeyManager()

    // hotkey id -> action. Read from a @convention(c) callback, so it lives on
    // the singleton rather than being captured.
    fileprivate var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var installed = false

    /// Common modifier mask: Command + Option.
    static let cmdOpt = UInt32(cmdKey | optionKey)

    /// Virtual key codes we use (kVK_ANSI_*).
    static let keyA: UInt32 = 0x00
    static let keyS: UInt32 = 0x01
    static let keyC: UInt32 = 0x08

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, _ handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        handlers[id] = handler

        let hotKeyID = EventHotKeyID(signature: OSType(0x474C_4E43), id: id) // 'GLNC'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref = ref {
            refs.append(ref)
            return true
        }
        handlers[id] = nil
        return false
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            let id = hkID.id
            DispatchQueue.main.async {
                HotKeyManager.shared.handlers[id]?()
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
