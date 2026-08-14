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
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        if let ax = grabViaAccessibility(), !ax.text.isEmpty {
            return Capture(text: ax.text, context: ax.context, sourceApp: app)
        }
        if let copied = grabViaClipboard(), !copied.isEmpty {
            return Capture(text: copied, context: nil, sourceApp: app)
        }
        return nil
    }

    // MARK: - Accessibility

    private static func grabViaAccessibility() -> (text: String, context: String?)? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused as! AXUIElement?
        else { return nil }

        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String
        else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return (trimmed, sentenceAround(element: element, selection: trimmed))
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

    // MARK: - Fallback через ⌘C

    /// Для приложений без нормальной AX-поддержки. Буфер обмена сохраняем и
    /// возвращаем на место, чтобы не портить пользователю копипаст.
    private static func grabViaClipboard() -> String? {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { dict[type] = item.data(forType: type) }
            return dict
        }
        let changeCountBefore = pb.changeCount

        sendCommandC()
        // ждём, пока целевое приложение обработает ⌘C
        let deadline = Date().addingTimeInterval(0.35)
        while pb.changeCount == changeCountBefore, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

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

    private static func sendCommandC() {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
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
