import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let onboardedKey = "mrdi.onboarded"

    /// Последняя снятая область: по «переснять» она переснимается без выделения —
    /// один хоткей на каждую новую строку субтитров.
    private var lastRegion: (rect: NSRect, screen: NSScreen)?
    private var appToRestore: NSRunningApplication?
    private var listenItem: NSMenuItem?
    private var reviewItem: NSMenuItem?
    private var loginItem: NSMenuItem?
    /// Пункты меню, у которых есть глобальное сочетание: их подписи
    /// обновляются вместе с настройками.
    private var shortcutItems: [HotkeyAction: NSMenuItem] = [:]
    private let listenKey = "mrdi.listen"
    private let listenSeconds: Double = 15
    private var dictationStart: Date?
    private var dictationLatched = false
    private var dictationLocale = "en-US"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        _ = Store.shared          // открыть базу и домигрировать схему заранее,
        HUDController.shared.warmUp()   // чтобы первый же перевод не ждал диск
        registerHotkeys()
        LoginItem.ensureEnabled()   // после перезагрузки перевод должен работать без ручного запуска
        HotkeySettings.shared.onChange = { [weak self] in self?.registerHotkeys() }
        ScreenCapture.prewarm()

        SystemAudioRecorder.shared.onStop = { [weak self] error in
            self?.updateListenItem()
            if let error {
                HUDController.shared.showMessage("Прослушивание остановлено: \(error.localizedDescription)")
            }
        }
        if UserDefaults.standard.bool(forKey: listenKey) { startListening() }

        // тем, кто уже всё настроил до появления окна настройки, его не показываем
        if UserDefaults.standard.bool(forKey: onboardedKey), SelectionCapture.isTrusted {
            UserDefaults.standard.set(true, forKey: SetupWindow.doneKey)
        }
        // первый запуск или пропал главный доступ: без окна приложение выглядит
        // как «ничего не произошло», а нужный переключатель спрятан в настройках
        if SetupWindow.isNeeded {
            SetupWindow.shared.show()
        }
    }

    // MARK: - Меню-бар

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "character.book.closed.fill", accessibilityDescription: "Словарь")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        add(to: menu, title: "Словарь…", hotkey: .openDictionary, action: #selector(openWordList))
        reviewItem = add(to: menu, title: "Повторение…", action: #selector(openReview))
        add(to: menu, title: "Перевести выделенное", hotkey: .lookupSelection, action: #selector(lookupSelection))
        add(to: menu, title: "Ввести слово…", hotkey: .typeText, action: #selector(typeText))
        add(to: menu, title: "Перевести область экрана", hotkey: .screenRegion, action: #selector(lookupScreenRegion))
        add(to: menu, title: "Переснять ту же область", hotkey: .repeatRegion, action: #selector(repeatLastRegion))
        add(to: menu, title: "Что прозвучало только что", hotkey: .listenBack, action: #selector(listenBack))
        add(to: menu, title: "Сказать по-английски", hotkey: .voiceEnglish, action: #selector(dictateEnglish))
        add(to: menu, title: "Сказать по-русски", hotkey: .voiceRussian, action: #selector(dictateRussian))
        menu.addItem(.separator())
        listenItem = add(to: menu, title: "Слушать системный звук", action: #selector(toggleListening))
        loginItem = add(to: menu, title: "Запускать при входе", action: #selector(toggleLoginItem))
        menu.addItem(.separator())
        add(to: menu, title: "Сочетания клавиш…", action: #selector(openSettings))
        add(to: menu, title: "Как пользоваться…", action: #selector(openSetup))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Пункты меню показывают то же сочетание, что работает глобально,
    /// чтобы хоткеи вообще можно было найти.
    @discardableResult
    private func add(to menu: NSMenu, title: String, hotkey: HotkeyAction? = nil, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let hotkey { shortcutItems[hotkey] = item }
        menu.addItem(item)
        return item
    }

    /// Меню и подсказка у иконки повторяют текущие сочетания — после переназначения
    /// старые подписи только сбивали бы с толку.
    private func updateShortcutLabels() {
        let settings = HotkeySettings.shared
        for (action, item) in shortcutItems {
            let equivalent = settings.shortcut(for: action).menuKeyEquivalent
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.modifiers
        }
        statusItem?.button?.toolTip = "MrDi — \(settings.shortcut(for: .lookupSelection).display) перевести выделенное, "
            + "\(settings.shortcut(for: .openDictionary).display) словарь"
    }

    // MARK: - Хоткеи

    private func registerHotkeys() {
        updateShortcutLabels()
        let settings = HotkeySettings.shared
        HotkeyManager.shared.replaceAll([
            (settings.shortcut(for: .lookupSelection), { [weak self] in self?.lookupSelection() }, nil),
            (settings.shortcut(for: .typeText), { [weak self] in self?.typeText() }, nil),
            (settings.shortcut(for: .openDictionary), { [weak self] in self?.openWordList() }, nil),
            (settings.shortcut(for: .screenRegion), { [weak self] in self?.lookupScreenRegion() }, nil),
            (settings.shortcut(for: .repeatRegion), { [weak self] in self?.repeatLastRegion() }, nil),
            (settings.shortcut(for: .listenBack), { [weak self] in self?.listenBack() }, nil),
            (settings.shortcut(for: .voiceEnglish),
             { [weak self] in self?.dictationPressed(locale: "en-US") },
             { [weak self] in self?.dictationReleased() }),
            (settings.shortcut(for: .voiceRussian),
             { [weak self] in self?.dictationPressed(locale: "ru-RU") },
             { [weak self] in self?.dictationReleased() })
        ])
    }

    @objc private func lookupSelection() {
        // повторное нажатие при открытой подсказке просто закрывает её
        if HUDController.shared.isVisible {
            HUDController.shared.hide()
            return
        }
        guard SelectionCapture.isTrusted else {
            SetupWindow.shared.show()
            return
        }
        guard let capture = SelectionCapture.grab() else {
            HUDController.shared.showMessage("Ничего не выделено")
            return
        }
        HUDController.shared.lookup(capture, mode: "selection")
    }

    /// Слово, которого нет на экране: набрать его самому. Повторное нажатие закрывает поле.
    @objc private func typeText() {
        if HUDController.shared.isTyping {
            HUDController.shared.hide()
            return
        }
        HUDController.shared.beginTyping()
    }

    // MARK: - Микрофон

    /// Сочетание работает двумя способами сразу: зажать и говорить, либо коротко
    /// нажать, сказать и нажать ещё раз. Угадывать, какой из них имел в виду
    /// пользователь, не нужно — решает длительность удержания.
    private func dictationPressed(locale: String) {
        if MicRecorder.shared.isRecording {
            if dictationLatched { finishDictation() }
            return
        }
        startDictation(locale: locale)
    }

    private func dictationReleased() {
        guard MicRecorder.shared.isRecording, let start = dictationStart else { return }
        if Date().timeIntervalSince(start) < 0.4 {
            dictationLatched = true
            HUDController.shared.updateListening(hint: "\(voiceStopHint) — закончить, ␛ — отменить")
        } else {
            finishDictation()
        }
    }

    private var voiceStopHint: String {
        HotkeySettings.shared.shortcut(for: dictationLocale == "ru-RU" ? .voiceRussian : .voiceEnglish).display
    }

    private func startDictation(locale: String) {
        guard MicRecorder.hasMicrophoneAccess, Transcriber.isAuthorized else {
            Task {
                _ = await MicRecorder.requestMicrophoneAccess()
                _ = await Transcriber.requestAuthorization()
                HUDController.shared.showMessage("Разрешите микрофон и распознавание речи, затем нажмите ещё раз")
            }
            return
        }

        dictationLocale = locale
        dictationStart = Date()
        dictationLatched = false
        let language = locale == "ru-RU" ? "по-русски" : "по-английски"
        HUDController.shared.showListening(hint: "Говорите \(language), затем отпустите клавиши")
        MicRecorder.shared.onPartial = { partial in
            HUDController.shared.updateListening(partial)
        }

        do {
            try MicRecorder.shared.start(locale: locale)
        } catch {
            HUDController.shared.showMessage(error.localizedDescription)
            return
        }

        // предохранитель на случай потерянного события отпускания клавиши
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard MicRecorder.shared.isRecording else { return }
            self?.finishDictation()
        }
    }

    private func finishDictation() {
        guard MicRecorder.shared.isRecording else { return }
        let anchor = NSEvent.mouseLocation
        HUDController.shared.updateListening(hint: "Распознаю…")

        Task {
            let text = await MicRecorder.shared.stop()
            dictationLatched = false
            dictationStart = nil
            guard !text.isEmpty else {
                HUDController.shared.showMessage("Не расслышал — попробуйте ещё раз, ближе к микрофону")
                return
            }
            HUDController.shared.lookup(
                Capture(text: text, context: nil, sourceApp: "Микрофон"),
                mode: "voice", anchor: anchor)
        }
    }

    // MARK: - Системный звук

    /// Прослушивание выключено по умолчанию и включается вручную:
    /// фоновый буфер всего, что звучит на компьютере, не должен появляться сам собой.
    @objc private func toggleListening() {
        if SystemAudioRecorder.shared.isRunning {
            UserDefaults.standard.set(false, forKey: listenKey)
            Task {
                await SystemAudioRecorder.shared.stop()
                updateListenItem()
            }
        } else {
            UserDefaults.standard.set(true, forKey: listenKey)
            startListening()
        }
    }

    private func startListening() {
        guard ScreenCapture.hasPermission else {
            ScreenCapture.requestPermission()
            HUDController.shared.showMessage("Для звука нужен тот же доступ: Конфиденциальность → Запись экрана")
            return
        }
        Task {
            _ = await Transcriber.requestAuthorization()
            do {
                try await SystemAudioRecorder.shared.start()
            } catch {
                HUDController.shared.showMessage("Не удалось начать прослушивание: \(error.localizedDescription)")
            }
            updateListenItem()
        }
    }

    private func updateListenItem() {
        let on = SystemAudioRecorder.shared.isRunning
        listenItem?.state = on ? .on : .off
        statusItem?.button?.image = NSImage(
            systemSymbolName: on ? "character.book.closed.fill" : "character.book.closed",
            accessibilityDescription: "Словарь")
        statusItem?.button?.image?.isTemplate = true
    }

    @objc private func listenBack() {
        guard SystemAudioRecorder.shared.isRunning else {
            let key = HotkeySettings.shared.shortcut(for: .listenBack).display
            HUDController.shared.showMessage("Включите «Слушать системный звук» в меню — тогда \(key) покажет расшифровку последних \(Int(listenSeconds)) секунд")
            return
        }
        guard let buffer = SystemAudioRecorder.shared.recentAudio(seconds: listenSeconds) else {
            HUDController.shared.showMessage("Пока нечего разбирать — звук ещё не шёл")
            return
        }

        let anchor = NSEvent.mouseLocation
        HUDController.shared.showLoading("Разбираю последние \(Int(listenSeconds)) секунд…", anchor: anchor)
        Task {
            do {
                let text = try await Transcriber.transcribe(buffer)
                HUDController.shared.showTranscript(text, anchor: anchor)
            } catch {
                HUDController.shared.showMessage(error.localizedDescription)
            }
        }
    }

    // MARK: - Область экрана

    @objc private func lookupScreenRegion() {
        guard !RegionSelector.shared.isActive else { return }
        guard ScreenCapture.hasPermission else {
            ScreenCapture.requestPermission()
            HUDController.shared.showMessage(ScreenCaptureError.noPermission.localizedDescription)
            return
        }
        HUDController.shared.hide()
        appToRestore = NSWorkspace.shared.frontmostApplication

        RegionSelector.shared.begin { [weak self] result in
            guard let self else { return }
            guard let (rect, screen) = result else {
                self.restoreFrontmostApp()
                return
            }
            self.lastRegion = (rect, screen)
            self.captureAndLookup(rect: rect, screen: screen)
        }
    }

    @objc private func repeatLastRegion() {
        guard let last = lastRegion else {
            lookupScreenRegion()   // области ещё не было — просим выделить
            return
        }
        HUDController.shared.hide()
        captureAndLookup(rect: last.rect, screen: last.screen)
    }

    private func captureAndLookup(rect: NSRect, screen: NSScreen) {
        // подсказка встаёт под самой областью, а не под курсором:
        // для строки субтитров это единственное место, где она не мешает
        let anchor = NSPoint(x: rect.minX, y: rect.minY - 6)

        Task {
            do {
                // даём оверлею выделения исчезнуть с экрана до снимка
                try await Task.sleep(nanoseconds: 60_000_000)
                restoreFrontmostApp()
                let image = try await ScreenCapture.capture(rect: rect, on: screen)
                let text = try OCR.recognize(image)
                HUDController.shared.lookup(
                    Capture(text: text, context: nil, sourceApp: "Экран"),
                    mode: "ocr", anchor: anchor)
            } catch {
                HUDController.shared.showMessage(error.localizedDescription)
            }
        }
    }

    private func restoreFrontmostApp() {
        // выделение области забирает фокус — возвращаем его туда, где был пользователь
        appToRestore?.activate()
        appToRestore = nil
    }

    @objc private func openWordList() {
        HUDController.shared.hide()
        WordListWindow.shared.show(mode: .dictionary)
    }

    @objc private func openReview() {
        HUDController.shared.hide()
        WordListWindow.shared.show(mode: .review)
    }

    @objc private func toggleLoginItem() {
        LoginItem.userSet(!LoginItem.isEnabled)
        loginItem?.state = LoginItem.isEnabled ? .on : .off
    }

    /// Счётчик слов к повторению считается в момент открытия меню:
    /// держать его актуальным постоянно незачем, а так он всегда верный.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let due = Store.shared.dueCount()
        reviewItem?.title = due > 0 ? "Повторение — \(due)" : "Повторение…"
        loginItem?.state = LoginItem.isEnabled ? .on : .off
        listenItem?.state = SystemAudioRecorder.shared.isRunning ? .on : .off
    }

    @objc private func dictateEnglish() { dictationPressed(locale: "en-US") }
    @objc private func dictateRussian() { dictationPressed(locale: "ru-RU") }

    @objc private func openSettings() {
        HUDController.shared.hide()
        SettingsWindow.shared.show()
    }

    @objc private func openSetup() {
        SetupWindow.shared.show()
    }
}
