import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Панель-подсказка. Никогда не становится key-окном и не активирует приложение:
/// видео продолжает играть, курсор остаётся там, где был.
@MainActor
final class HUDController {
    static let shared = HUDController()

    private let model = HUDModel()
    private var panel: HUDPanel!
    private var current: LookupResult?
    private var hideWorkItem: DispatchWorkItem?
    private(set) var isVisible = false

    private let panelWidth: CGFloat = 400
    private var contentHeight: CGFloat = 120
    private var anchor: NSPoint = .zero
    private var lastTranscript: String?
    private var lookupTask: Task<Void, Never>?
    private var wantsMouse = false   // расшифровка: слова в ней кликабельны
    private var isClipped = false    // не влезла в экран: нужна прокрутка колесом

    /// Режим ввода с клавиатуры: единственный случай, когда панель забирает фокус.
    private(set) var isTyping = false
    private var typingQuery = ""         // текст, для которого получен `current`
    private var typingTask: Task<Void, Never>?
    private var saveWhenReady = false    // ⏎ нажат раньше, чем доехал перевод
    private var editMonitor: Any?

    /// Зазор до края экрана и до курсора.
    private let margin: CGFloat = 8

    private var offscreenOrigin: NSPoint { NSPoint(x: -panelWidth - 80, y: 0) }

    private init() {}

    /// Создаём панель и сессии перевода сразу на старте,
    /// чтобы первый запрос не ждал ни верстки, ни прогрева переводчика.
    func warmUp() {
        guard panel == nil else { return }
        TranslationHostWindow.install()
        let p = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: contentHeight),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.appearance = NSAppearance(named: .darkAqua)   // панель всегда тёмная, поверх любого контента
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let hosting = NSHostingView(rootView: HUDView(
            model: model,
            onSize: { [weak self] size in self?.updateContentHeight(size.height) },
            onWordTap: { [weak self] word in self?.lookupWordFromTranscript(word) },
            onInput: { [weak self] text in self?.inputChanged(text) }
        ))
        // размер окна задаём только мы: иначе NSHostingView сам растягивает его
        // вниз по мере прихода перевода, мимо проверки границ экрана
        hosting.sizingOptions = []
        p.contentView = hosting
        p.alphaValue = 0
        p.setFrameOrigin(offscreenOrigin)
        panel = p

        KeyInterceptor.shared.onKeyDown = { [weak self] code in
            guard let self, self.isVisible else { return false }
            // при вводе буквы нужны полю: перехватываем только ⏎, ␛ и ⌘P
            if self.isTyping {
                switch code {
                case KeyCode.escape:
                    DispatchQueue.main.async { self.hide() }
                    return true
                case KeyCode.ret, KeyCode.keypadEnter:
                    DispatchQueue.main.async { self.submitTyping() }
                    return true
                case KeyCode.p where CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand):
                    DispatchQueue.main.async { self.speakCurrent() }
                    return true
                default:
                    return false
                }
            }
            switch code {
            case KeyCode.escape:
                DispatchQueue.main.async { self.hide() }
                return true
            case KeyCode.ret, KeyCode.keypadEnter:
                DispatchQueue.main.async { self.saveCurrent() }
                return true
            case KeyCode.p:
                DispatchQueue.main.async { self.speakCurrent() }
                return true
            default:
                return false
            }
        }
        KeyInterceptor.shared.onMouseDown = { [weak self] in
            guard let self, self.isVisible else { return }
            // клик по самой подсказке — это выбор слова в расшифровке, а не «закрыть»
            if self.panel.frame.contains(NSEvent.mouseLocation) { return }
            self.hide()
        }
    }

    // MARK: - Публичный вход

    /// Расшифровка последних секунд звука: слова в ней кликабельны,
    /// поэтому панель на это время начинает принимать мышь.
    func showTranscript(_ text: String, anchor: NSPoint? = nil) {
        warmUp()
        leaveTyping()
        current = nil
        lastTranscript = text
        model.justSaved = false
        model.state = .transcript(text)
        setInteractive(true)
        show(at: anchor)
    }

    private func lookupWordFromTranscript(_ word: String) {
        let context = lastTranscript
        lookup(Capture(text: word, context: context, sourceApp: "Звук"),
               mode: "audio", anchor: NSPoint(x: panel.frame.minX + 30, y: panel.frame.maxY))
    }

    func lookup(_ capture: Capture, mode: String, anchor: NSPoint? = nil) {
        warmUp()
        leaveTyping()
        setInteractive(false)
        current = nil
        model.justSaved = false
        model.state = .loading(capture.text)
        model.seenCount = 0
        model.alreadySaved = false
        show(at: anchor)
        runLookup(capture, mode: mode, record: true)
    }

    private func runLookup(_ capture: Capture, mode: String, record: Bool) {
        lookupTask?.cancel()
        lookupTask = Task {
            switch await Lookup.base(capture, mode: mode, record: record) {
            case .failure(let error):
                guard !Task.isCancelled, isVisible else { return }
                model.state = .error(error.localizedDescription)
                saveWhenReady = false
                // при вводе ошибка — промежуточное состояние, а не повод закрыть поле
                if !isTyping { scheduleAutoHide(after: 2.5) }

            case .success(var result):
                guard !Task.isCancelled, isVisible else { return }
                current = result
                if isTyping { typingQuery = capture.text }
                model.justSaved = false
                model.state = .result(result)
                NotificationCenter.default.post(name: .mrdiLookupSucceeded, object: nil)
                model.alreadySaved = Store.shared.isSaved(lemma: result.lemma.lowercased())
                // ввод попадает в историю при закрытии, поэтому текущий раз досчитываем сами
                model.seenCount = Store.shared.lookupCount(lemma: result.lemma.lowercased()) + (record ? 0 : 1)
                if saveWhenReady {
                    saveWhenReady = false
                    saveCurrent()
                    return
                }

                // словарная статья и перевод предложения догоняют перевод слова
                async let article = result.isPhrase ? nil : DictionaryService.entry(for: result.lemma)
                async let sentence = Lookup.contextTranslation(capture.context)

                if let article = await article, !Task.isCancelled, isVisible {
                    result.ipa = article.ipa
                    result.senses = article.senses
                    current = result
                    model.state = .result(result)
                }
                if let sentence = await sentence, !Task.isCancelled, isVisible {
                    result.contextTranslation = sentence
                    current = result
                    model.state = .result(result)
                }
            }
        }
    }

    func showListening(hint: String) {
        warmUp()
        leaveTyping()
        setInteractive(false)
        lookupTask?.cancel()
        hideWorkItem?.cancel()
        current = nil
        model.listenHint = hint
        model.state = .listening("")
        show(at: NSEvent.mouseLocation)
    }

    func updateListening(_ partial: String? = nil, hint: String? = nil) {
        if let hint { model.listenHint = hint }
        if let partial, case .listening = model.state { model.state = .listening(partial) }
    }

    func showLoading(_ text: String, anchor: NSPoint? = nil) {
        warmUp()
        leaveTyping()
        setInteractive(false)
        current = nil
        model.state = .loading(text)
        show(at: anchor)
    }

    func showMessage(_ text: String) {
        warmUp()
        leaveTyping()
        setInteractive(false)
        current = nil
        model.state = .error(text)
        show(at: nil)
        scheduleAutoHide(after: 4)
    }

    // MARK: - Ввод с клавиатуры

    /// Поле ввода в той же панели: перевод появляется по мере набора, язык
    /// определяется по алфавиту — русское слово даёт английское и наоборот.
    func beginTyping() {
        warmUp()
        lookupTask?.cancel()
        typingTask?.cancel()
        current = nil
        typingQuery = ""
        saveWhenReady = false
        model.justSaved = false
        model.alreadySaved = false
        model.seenCount = 0
        model.input = ""
        model.state = .prompt
        isTyping = true
        model.isTyping = true
        model.typingSession += 1
        setInteractive(true)
        installEditMonitor()
        show(at: NSEvent.mouseLocation)
        // панель не активирует приложение: клавиатура уходит в поле,
        // а то, что было на экране, остаётся активным
        panel.allowsKey = true
        panel.makeKeyAndOrderFront(nil)
    }

    private func inputChanged(_ text: String) {
        guard isTyping else { return }
        typingTask?.cancel()
        saveWhenReady = false
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            lookupTask?.cancel()
            current = nil
            typingQuery = ""
            model.state = .prompt
            return
        }
        // короткая пауза, чтобы не переводить каждую букву на полпути к слову
        typingTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, isTyping else { return }
            runLookup(Capture(text: query, context: nil, sourceApp: "Ввод"), mode: "typed", record: false)
        }
    }

    /// ⏎ — в словарь. Если перевод набранного ещё не доехал, сохраняем, как только доедет.
    private func submitTyping() {
        let query = model.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        if current != nil, typingQuery == query {
            saveCurrent()
            return
        }
        typingTask?.cancel()
        saveWhenReady = true
        runLookup(Capture(text: query, context: nil, sourceApp: "Ввод"), mode: "typed", record: false)
    }

    /// Любой другой режим занимает панель — поле ввода закрывается и отдаёт клавиатуру.
    private func leaveTyping() {
        guard isTyping else { return }
        endTyping()
        panel.orderOut(nil)
    }

    private func endTyping() {
        // в историю просмотров уходит только то, на чём пользователь остановился
        if let r = current {
            Store.shared.recordLookup(lemma: r.lemma.lowercased(), mode: "typed")
        }
        isTyping = false
        model.isTyping = false
        typingTask?.cancel()
        saveWhenReady = false
        panel.allowsKey = false
        removeEditMonitor()
    }

    /// У приложения нет главного меню, а без него ⌘V, ⌘C, ⌘A и ⌘Z
    /// в текстовом поле не работают. Отдаём их полю сами.
    private func installEditMonitor() {
        guard editMonitor == nil else { return }
        editMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])
            let action: Selector?
            switch (Int(event.keyCode), flags) {
            case (kVK_ANSI_V, .command): action = #selector(NSText.paste(_:))
            case (kVK_ANSI_C, .command): action = #selector(NSText.copy(_:))
            case (kVK_ANSI_X, .command): action = #selector(NSText.cut(_:))
            case (kVK_ANSI_A, .command): action = #selector(NSText.selectAll(_:))
            case (kVK_ANSI_Z, .command): action = Selector(("undo:"))
            case (kVK_ANSI_Z, [.command, .shift]): action = Selector(("redo:"))
            default: action = nil
            }
            guard let action else { return event }
            return NSApp.sendAction(action, to: nil, from: nil) ? nil : event
        }
    }

    private func removeEditMonitor() {
        if let editMonitor { NSEvent.removeMonitor(editMonitor) }
        editMonitor = nil
    }

    // MARK: - Показ / скрытие

    private func show(at point: NSPoint? = nil) {
        hideWorkItem?.cancel()
        anchor = point ?? NSEvent.mouseLocation
        layout()
        panel.orderFrontRegardless()
        isVisible = true
        KeyInterceptor.shared.start()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.09
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        MicRecorder.shared.cancel()   // ␛ во время диктовки должен её отменять
        lookupTask?.cancel()
        hideWorkItem?.cancel()
        setInteractive(false)
        KeyInterceptor.shared.stop()
        if isTyping {
            endTyping()
            // клавиатура должна вернуться туда, где была, сразу,
            // а не через анимацию: следующая буква уже летит
            panel.orderOut(nil)
            panel.alphaValue = 0
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.panel.orderOut(nil)
                self.panel.setFrameOrigin(self.offscreenOrigin)
            }
        }
    }

    private func setInteractive(_ interactive: Bool) {
        wantsMouse = interactive
        panel?.ignoresMouseEvents = !(wantsMouse || isClipped)
    }

    private func scheduleAutoHide(after seconds: TimeInterval) {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func speakCurrent() {
        guard let r = current else { return }
        Speaker.speak(r.lemma)   // lemma всегда английская сторона, в любом направлении
    }

    private func saveCurrent() {
        guard let r = current else { return }
        Store.shared.save(r)
        model.alreadySaved = true
        model.justSaved = true
        saveWhenReady = false
        WordListWindow.shared.refreshIfOpen()
        scheduleAutoHide(after: 0.7)
    }

    /// Высота приходит из SwiftUI после верстки: длинный перевод с контекстом
    /// не должен обрезаться, короткое слово не должно оставлять пустоту.
    private func updateContentHeight(_ height: CGFloat) {
        let target = max(80, height) + 20   // +20 — внешние отступы под тень
        guard abs(target - contentHeight) > 1 else { return }
        contentHeight = target
        if isVisible { layout() }
    }

    /// Панель появляется рядом с курсором и целиком помещается на экран:
    /// под курсором, если там хватает места, иначе над ним, иначе там, где места больше.
    /// Выше экрана панель не растёт — остальное прокручивается колесом.
    private func layout() {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) }
            ?? NSScreen.screens.min { distance($0.frame, anchor) < distance($1.frame, anchor) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame.insetBy(dx: margin, dy: margin) else { return }

        let height = min(contentHeight, visible.height)
        isClipped = height < contentHeight
        panel.ignoresMouseEvents = !(wantsMouse || isClipped)

        // поле ввода стоит на одном месте, как Spotlight: верхний край не прыгает,
        // пока под ним появляется и меняется перевод
        if isTyping {
            let top = visible.maxY - visible.height * 0.22
            let y = min(max(top - height, visible.minY), visible.maxY - height)
            let x = visible.midX - panelWidth / 2
            panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: height), display: true)
            return
        }

        let spaceBelow = anchor.y - 12 - visible.minY
        let spaceAbove = visible.maxY - (anchor.y + 22)
        var y: CGFloat
        if height <= spaceBelow {
            y = anchor.y - 12 - height
        } else if height <= spaceAbove {
            y = anchor.y + 22
        } else {
            y = spaceBelow >= spaceAbove ? visible.minY : visible.maxY - height
        }
        y = min(max(y, visible.minY), visible.maxY - height)

        var x = anchor.x - 30
        x = min(max(x, visible.minX), visible.maxX - panelWidth)

        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: height), display: true)
    }

    private func distance(_ rect: NSRect, _ point: NSPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}

/// Панель-подсказка обычно не принимает клавиатуру. Исключение — режим ввода:
/// там она становится key-окном, не активируя приложение.
final class HUDPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
}
