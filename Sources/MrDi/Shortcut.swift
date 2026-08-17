import AppKit
import Carbon.HIToolbox

/// Сочетание клавиш в терминах Carbon — именно в них его регистрирует система.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    var display: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + Self.keyName(keyCode)
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Из события AppKit — так сочетание записывается с клавиатуры в настройках.
    init?(event: NSEvent) {
        var carbon: UInt32 = 0
        if event.modifierFlags.contains(.control) { carbon |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { carbon |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { carbon |= UInt32(cmdKey) }

        // без модификатора сочетание перехватывало бы обычную клавишу во всей системе
        guard carbon != 0 else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.modifiers = carbon
    }

    static func keyName(_ keyCode: UInt32) -> String {
        if let special = specialKeys[keyCode] { return special }
        return character(for: keyCode) ?? "клавиша \(keyCode)"
    }

    private static let specialKeys: [UInt32: String] = [
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "⏎", UInt32(kVK_Escape): "␛",
        UInt32(kVK_Tab): "⇥", UInt32(kVK_Delete): "⌫",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12"
    ]

    /// Буква на клавише берётся из текущей раскладки: на русской раскладке
    /// та же физическая клавиша должна показываться как «В», а не как «D».
    private static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

/// Действия, которым можно назначить сочетание.
enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case lookupSelection
    case screenRegion
    case repeatRegion
    case voiceEnglish
    case voiceRussian
    case listenBack
    case openDictionary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lookupSelection: return "Перевести выделенное"
        case .screenRegion: return "Перевести область экрана"
        case .repeatRegion: return "Переснять ту же область"
        case .voiceEnglish: return "Сказать по-английски"
        case .voiceRussian: return "Сказать по-русски"
        case .listenBack: return "Что прозвучало только что"
        case .openDictionary: return "Открыть словарь"
        }
    }

    var hint: String? {
        switch self {
        case .voiceEnglish: return "английское слово → русский перевод"
        case .voiceRussian: return "русское слово → английское"
        case .repeatRegion: return "для субтитров: обвели один раз, дальше только эта клавиша"
        default: return nil
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .lookupSelection: return Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        case .screenRegion: return Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey))
        case .repeatRegion: return Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey))
        case .voiceEnglish: return Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey))
        case .voiceRussian: return Shortcut(keyCode: UInt32(kVK_ANSI_V),
                                            modifiers: UInt32(optionKey) | UInt32(shiftKey))
        case .listenBack: return Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey))
        case .openDictionary: return Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey))
        }
    }
}

@MainActor
final class HotkeySettings: ObservableObject {
    static let shared = HotkeySettings()

    @Published private(set) var shortcuts: [HotkeyAction: Shortcut] = [:]

    /// Вызывается после любого изменения, чтобы перерегистрировать сочетания в системе.
    var onChange: (() -> Void)?

    private let storageKey = "mrdi.shortcuts"

    private init() {
        let stored = (try? JSONDecoder().decode([String: Shortcut].self,
                                                from: UserDefaults.standard.data(forKey: storageKey) ?? Data()))
        var result: [HotkeyAction: Shortcut] = [:]
        for action in HotkeyAction.allCases {
            result[action] = stored?[action.rawValue] ?? action.defaultShortcut
        }
        shortcuts = result
    }

    func shortcut(for action: HotkeyAction) -> Shortcut {
        shortcuts[action] ?? action.defaultShortcut
    }

    /// Возвращает действие, которое уже занимает это сочетание.
    func conflict(with shortcut: Shortcut, excluding action: HotkeyAction) -> HotkeyAction? {
        shortcuts.first { $0.key != action && $0.value == shortcut }?.key
    }

    func set(_ shortcut: Shortcut, for action: HotkeyAction) {
        shortcuts[action] = shortcut
        persist()
    }

    func reset(_ action: HotkeyAction) {
        shortcuts[action] = action.defaultShortcut
        persist()
    }

    func resetAll() {
        for action in HotkeyAction.allCases { shortcuts[action] = action.defaultShortcut }
        persist()
    }

    private func persist() {
        let raw = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        onChange?()
    }
}
