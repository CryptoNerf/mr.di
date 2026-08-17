import AppKit

/// Перехват Enter/Esc, пока висит подсказка.
///
/// Панель намеренно НЕ становится key-окном: фокус остаётся у видео или у текста,
/// пользователь не выпадает из контекста. Поэтому клавиши ловим event-tap'ом и
/// проглатываем только те, что нам нужны — остальные уходят в активное приложение.
final class KeyInterceptor {
    static let shared = KeyInterceptor()

    /// Возврат true — событие поглощается и до активного приложения не доходит.
    var onKeyDown: ((Int64) -> Bool)?

    /// Временный перехватчик поверх основного: на время выделения области
    /// клавиши принадлежат ему, а не подсказке.
    var onKeyDownOverride: ((Int64) -> Bool)?
    var onMouseDown: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isRunning = false

    private init() {}

    @discardableResult
    func start() -> Bool {
        if tap == nil, !createTap() { return false }
        guard let tap else { return false }
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        isRunning = false
    }

    private func createTap() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.leftMouseDown.rawValue)
                 | (1 << CGEventType.rightMouseDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            switch type {
            case .keyDown:
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                if let override = KeyInterceptor.shared.onKeyDownOverride {
                    if override(code) { return nil }
                } else if KeyInterceptor.shared.onKeyDown?(code) == true {
                    return nil
                }
            case .leftMouseDown, .rightMouseDown:
                DispatchQueue.main.async { KeyInterceptor.shared.onMouseDown?() }
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if let t = KeyInterceptor.shared.tap { CGEvent.tapEnable(tap: t, enable: true) }
            default:
                break
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: callback,
                                          userInfo: nil) else {
            NSLog("[mrdi] event tap недоступен — нужен доступ к Универсальному доступу")
            return false
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false)
        return true
    }
}

enum KeyCode {
    static let escape: Int64 = 53
    static let ret: Int64 = 36
    static let keypadEnter: Int64 = 76
    static let p: Int64 = 35
    static let tab: Int64 = 48
}
