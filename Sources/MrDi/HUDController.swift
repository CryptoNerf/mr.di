import AppKit
import SwiftUI

/// Панель-подсказка. Никогда не становится key-окном и не активирует приложение:
/// видео продолжает играть, курсор остаётся там, где был.
@MainActor
final class HUDController {
    static let shared = HUDController()

    private let model = HUDModel()
    private var panel: NSPanel!
    private var current: LookupResult?
    private var hideWorkItem: DispatchWorkItem?
    private(set) var isVisible = false

    private let panelWidth: CGFloat = 400
    private var contentHeight: CGFloat = 120
    private var anchor: NSPoint = .zero
    private var lastTranscript: String?
    private var lookupTask: Task<Void, Never>?

    private var offscreenOrigin: NSPoint { NSPoint(x: -panelWidth - 80, y: 0) }

    private init() {}

    /// Создаём панель сразу на старте и держим на экране в прозрачном виде,
    /// чтобы сессия перевода внутри неё была прогрета к первому запросу.
    func warmUp() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: contentHeight),
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
            onWordTap: { [weak self] word in self?.lookupWordFromTranscript(word) }
        ))
        p.contentView = hosting
        p.alphaValue = 0
        p.setFrameOrigin(offscreenOrigin)
        p.orderFrontRegardless()
        panel = p

        KeyInterceptor.shared.onKeyDown = { [weak self] code in
            guard let self, self.isVisible else { return false }
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
        setInteractive(false)
        current = nil
        model.justSaved = false
        model.state = .loading(capture.text)
        model.seenCount = 0
        model.alreadySaved = false
        show(at: anchor)

        lookupTask?.cancel()
        lookupTask = Task {
            switch await Lookup.base(capture, mode: mode) {
            case .failure(let error):
                guard !Task.isCancelled, isVisible else { return }
                model.state = .error(error.localizedDescription)
                scheduleAutoHide(after: 2.5)

            case .success(var result):
                guard !Task.isCancelled, isVisible else { return }
                current = result
                model.state = .result(result)
                model.alreadySaved = Store.shared.isSaved(lemma: result.lemma.lowercased())
                model.seenCount = Store.shared.lookupCount(lemma: result.lemma.lowercased())

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
        setInteractive(false)
        current = nil
        model.state = .loading(text)
        show(at: anchor)
    }

    func showMessage(_ text: String) {
        warmUp()
        setInteractive(false)
        current = nil
        model.state = .error(text)
        show(at: nil)
        scheduleAutoHide(after: 4)
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
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                // не orderOut: окно должно остаться на экране, иначе внутри него
                // погибнет прогретая сессия перевода
                self.panel.setFrameOrigin(self.offscreenOrigin)
            }
        }
    }

    private func setInteractive(_ interactive: Bool) {
        panel?.ignoresMouseEvents = !interactive
    }

    private func scheduleAutoHide(after seconds: TimeInterval) {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func speakCurrent() {
        guard let r = current else { return }
        Speaker.speak(r.isPhrase ? r.surface : r.lemma)
    }

    private func saveCurrent() {
        guard let r = current else { return }
        Store.shared.save(r)
        model.alreadySaved = true
        model.justSaved = true
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

    /// Панель появляется рядом с курсором и не вылезает за край экрана.
    private func layout() {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        var origin = NSPoint(x: anchor.x - 30, y: anchor.y - contentHeight - 12)
        if origin.x + panelWidth > visible.maxX { origin.x = visible.maxX - panelWidth }
        if origin.x < visible.minX { origin.x = visible.minX }
        if origin.y < visible.minY { origin.y = anchor.y + 22 }              // не влезло снизу — показываем сверху
        if origin.y + contentHeight > visible.maxY { origin.y = visible.maxY - contentHeight }
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: panelWidth, height: contentHeight),
                       display: true)
    }
}
