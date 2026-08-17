import AppKit
import Carbon.HIToolbox

/// Глобальные горячие клавиши через Carbon RegisterEventHotKey —
/// единственный способ на macOS перехватить сочетание, когда приложение неактивно,
/// не требуя Accessibility-разрешения.
final class HotkeyManager {
    static let shared = HotkeyManager()

    private struct Registration {
        let ref: EventHotKeyRef
        let onPress: () -> Void
        let onRelease: (() -> Void)?
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    private init() {}

    /// Перерегистрация: старые сочетания снимаются, новые ставятся.
    /// Нужна каждый раз, когда пользователь меняет сочетание в настройках.
    func replaceAll(_ bindings: [(shortcut: Shortcut, onPress: () -> Void, onRelease: (() -> Void)?)]) {
        unregisterAll()
        for binding in bindings {
            register(binding.shortcut, onPress: binding.onPress, onRelease: binding.onRelease)
        }
    }

    @discardableResult
    func register(_ shortcut: Shortcut,
                  onPress: @escaping () -> Void,
                  onRelease: (() -> Void)? = nil) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D524449 /* MRDI */), id: id)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("[mrdi] не удалось зарегистрировать \(shortcut.display) (код \(status))")
            return false
        }
        registrations[id] = Registration(ref: ref, onPress: onPress, onRelease: onRelease)
        return true
    }

    func unregisterAll() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
    }

    fileprivate func fire(_ id: UInt32, pressed: Bool) {
        guard let registration = registrations[id] else { return }
        if pressed { registration.onPress() } else { registration.onRelease?() }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return noErr }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard err == noErr else { return noErr }
            let id = hkID.id
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { HotkeyManager.shared.fire(id, pressed: pressed) }
            return noErr
        }, 2, &specs, nil, nil)
    }
}
