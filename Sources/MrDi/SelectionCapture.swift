import AppKit
import ApplicationServices

struct Capture {
    var text: String
    var context: String?
    var sourceApp: String?
}

/// Достаёт выделенный текст из любого приложения.
/// Основной путь — Accessibility API: он не трогает буфер обмена и заодно
/// отдаёт предложение вокруг слова, что нужно для перевода по контексту.
enum SelectionCapture {

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    static func grab() -> Capture? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let app = frontmost?.localizedName
        // зависшее приложение не должно держать хоткей по шесть секунд
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)

        let focused = focusedElement(pid: frontmost?.processIdentifier)
        if let element = focused, let ax = selectedText(in: element) {
            return Capture(text: ax.text, context: ax.context, sourceApp: app)
        }
        // Chrome и Safari: у веб-страницы нет AXSelectedText, но выделение
        // отдаётся через текстовые маркеры — без буфера обмена
        if let element = focused, let web = selectedWebText(in: element) {
            return Capture(text: web, context: nil, sourceApp: app)
        }
        let copied = grabViaClipboard(pid: frontmost?.processIdentifier)
        if let copied, !copied.isEmpty {
            return Capture(text: copied, context: nil, sourceApp: app)
        }
        // без текста выделения: только путь, по которому не получилось,
        // чтобы по журналу было видно, в каком приложении что сломалось
        NSLog("[mrdi] выделение не получено: \(app ?? "?"), фокус \(focused.flatMap(role) ?? "нет")")
        return nil
    }

    // MARK: - Accessibility

    /// Системный запрос фокуса иногда не отвечает, хотя само приложение отвечает, —
    /// тогда спрашиваем приложение напрямую.
    private static func focusedElement(pid: pid_t?) -> AXUIElement? {
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                         kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let element = focused {
            return (element as! AXUIElement)
        }
        guard let pid else { return nil }
        if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                         kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let element = focused {
            return (element as! AXUIElement)
        }
        return nil
    }

    private static func role(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return value as? String
    }

    private static func selectedText(in element: AXUIElement) -> (text: String, context: String?)? {
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String
        else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return (trimmed, sentenceAround(element: element, selection: trimmed))
    }

    private static func selectedWebText(in element: AXUIElement) -> String? {
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &range) == .success,
              let range
        else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString,
                                                         range, &value) == .success
        else { return nil }
        let text = (value as? String) ?? (value as? NSAttributedString)?.string
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Предложение, внутри которого находится выделение — по нему потом
    /// выбирается нужное значение многозначного слова.
    private static func sentenceAround(element: AXUIElement, selection: String) -> String? {
        var whole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &whole) == .success,
              let full = whole as? String, full.count > selection.count
        else { return nil }

        var rangeRef: CFTypeRef?
        var location = 0
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let value = rangeRef as! AXValue? {
            var range = CFRange()
            if AXValueGetValue(value, .cfRange, &range) { location = range.location }
        } else if let r = full.range(of: selection) {
            location = full.distance(from: full.startIndex, to: r.lowerBound)
        }

        let ns = full as NSString
        guard location >= 0, location < ns.length else { return nil }

        let terminators = CharacterSet(charactersIn: ".!?\n")
        var start = location
        while start > 0, !terminators.contains(ns.character(at: start - 1).unicodeScalar) { start -= 1 }
        var end = location
        while end < ns.length, !terminators.contains(ns.character(at: end).unicodeScalar) { end += 1 }
        if end < ns.length { end += 1 }

        let sentence = ns.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.count > selection.count ? sentence : nil
    }

    // MARK: - Fallback через буфер обмена

    /// Для приложений, которые не отдают выделение через Accessibility (Telegram,
    /// Electron). Буфер обмена сохраняем и возвращаем на место, чтобы не портить
    /// пользователю копипаст.
    ///
    /// Сначала ⌘C с клавиатуры. Если буфер не изменился — нажимаем «Правка →
    /// Копировать» через Accessibility: этому пути всё равно, какие клавиши
    /// зажаты и какая раскладка включена.
    private static func grabViaClipboard(pid: pid_t?) -> String? {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { dict[type] = item.data(forType: type) }
            return dict
        }
        let changeCountBefore = pb.changeCount

        waitForModifiersRelease()
        sendCommandC()
        var copied = waitForChange(of: pb, from: changeCountBefore, timeout: 0.6)
        if !copied, let pid, pressCopyMenuItem(pid: pid) {
            copied = waitForChange(of: pb, from: changeCountBefore, timeout: 0.6)
        }

        // буфер не изменился — копировать было нечего; старое содержимое
        // буфера к выделению отношения не имеет, и трогать его незачем
        guard copied else { return nil }
        let result = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let saved {
            pb.clearContents()
            for entry in saved {
                let item = NSPasteboardItem()
                for (type, data) in entry { item.setData(data, forType: type) }
                pb.writeObjects([item])
            }
        }
        return result
    }

    private static func waitForChange(of pb: NSPasteboard, from count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while pb.changeCount == count, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return pb.changeCount != count
    }

    /// Пункт меню с ⌘C у каждого приложения свой, но на всё время работы
    /// приложения один и тот же — ищем его один раз.
    private static var copyItems: [pid_t: AXUIElement] = [:]

    private static func pressCopyMenuItem(pid: pid_t) -> Bool {
        if let cached = copyItems[pid],
           AXUIElementPerformAction(cached, kAXPressAction as CFString) == .success {
            return true
        }
        copyItems[pid] = nil
        guard let item = findCopyMenuItem(pid: pid) else { return false }
        copyItems[pid] = item
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    private static func findCopyMenuItem(pid: pid_t) -> AXUIElement? {
        func children(_ element: AXUIElement) -> [AXUIElement] {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
            return value as? [AXUIElement] ?? []
        }
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                            kAXMenuBarAttribute as CFString, &bar) == .success,
              let bar
        else { return nil }

        for barItem in children(bar as! AXUIElement) {
            for menu in children(barItem) {
                for item in children(menu) {
                    var char: CFTypeRef?
                    var modifiers: CFTypeRef?
                    AXUIElementCopyAttributeValue(item, kAXMenuItemCmdCharAttribute as CFString, &char)
                    AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &modifiers)
                    // модификаторы 0 — это «только ⌘»
                    if (char as? String)?.uppercased() == "C", (modifiers as? Int) == 0 { return item }
                }
            }
        }
        return nil
    }

    /// Хоткей срабатывает на нажатие, когда модификаторы (тот же ⌥) ещё
    /// зажаты. Система подмешивает их к синтетическому ⌘C, и приложение
    /// получает ⌥⌘C — это уже не «копировать». Поэтому ждём, пока пользователь
    /// отпустит клавиши, но не дольше полсекунды.
    private static func waitForModifiersRelease() {
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let deadline = Date().addingTimeInterval(0.5)
        while !CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private static func sendCommandC() {
        // собственное состояние источника — физически зажатые клавиши к событию не примешиваются
        guard let src = CGEventSource(stateID: .privateState) else { return }
        let key = CGKeyCode(8) // C
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

private extension unichar {
    var unicodeScalar: Unicode.Scalar { Unicode.Scalar(self) ?? " " }
}
