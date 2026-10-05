import AppKit
import AVFoundation
import Speech
import SwiftUI

extension Notification.Name {
    /// Перевод показан — окно настройки по нему понимает, что всё заработало.
    static let mrdiLookupSucceeded = Notification.Name("mrdi.lookupSucceeded")
}

/// Состояние разрешений. Системные настройки не сообщают об изменениях,
/// поэтому пока окно открыто, статусы перечитываются раз в секунду:
/// галочка появляется сама, как только пользователь щёлкнул переключатель.
@MainActor
final class SetupModel: ObservableObject {
    @Published var accessibility = false
    @Published var screen = false
    @Published var microphone = false
    @Published var microphoneDenied = false
    @Published var loginItem = false
    @Published var loginNeedsApproval = false
    @Published var triedLookup = false

    /// Системный диалог с запросом показывается только один раз — дальше
    /// кнопка ведёт прямо в нужный раздел настроек.
    @Published var askedAccessibility = false
    @Published var askedScreen = false

    func refresh() {
        accessibility = SelectionCapture.isTrusted
        screen = ScreenCapture.hasPermission
        microphone = MicRecorder.hasMicrophoneAccess && Transcriber.isAuthorized
        microphoneDenied = AVCaptureDevice.authorizationStatus(for: .audio) == .denied
            || SFSpeechRecognizer.authorizationStatus() == .denied
        loginItem = LoginItem.isEnabled
        loginNeedsApproval = LoginItem.needsApproval
    }

    func requestAccessibility() {
        if askedAccessibility {
            SetupWindow.openPrivacyPane("Privacy_Accessibility")
        } else {
            SelectionCapture.requestPermission()
            askedAccessibility = true
        }
    }

    /// Переключатель в настройках включён, а доступа нет: он остался от прошлой
    /// версии с другой подписью. Убираем устаревшую запись и просим заново —
    /// в списке появится свежая строка для этой версии.
    func resetAccessibility() {
        SetupWindow.resetPermission("Accessibility")
        SelectionCapture.requestPermission()
        askedAccessibility = true
    }

    func resetScreen() {
        SetupWindow.resetPermission("ScreenCapture")
        ScreenCapture.requestPermission()
        askedScreen = true
    }

    func requestScreen() {
        if askedScreen {
            SetupWindow.openPrivacyPane("Privacy_ScreenCapture")
        } else {
            ScreenCapture.requestPermission()
            askedScreen = true
        }
    }

    func requestMicrophone() {
        if microphoneDenied {
            SetupWindow.openPrivacyPane(AVCaptureDevice.authorizationStatus(for: .audio) == .denied
                                        ? "Privacy_Microphone" : "Privacy_SpeechRecognition")
            return
        }
        Task {
            _ = await MicRecorder.requestMicrophoneAccess()
            _ = await Transcriber.requestAuthorization()
            refresh()
        }
    }

    func setLoginItem(_ enabled: Bool) {
        LoginItem.userSet(enabled)
        refresh()
        loginNeedsApproval = LoginItem.needsApproval
    }
}

/// Окно первого запуска: разрешения, проба перевода и автозапуск — в одном месте.
/// Без него человек видит иконку в меню-баре и не понимает, что делать дальше:
/// нужные переключатели спрятаны в Системных настройках, а без Универсального
/// доступа приложение просто молчит.
@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    static let shared = SetupWindow()

    static let doneKey = "mrdi.setupDone"
    /// Приложение закрылось посреди настройки — чаще всего по кнопке
    /// «Закрыть и открыть заново» после выдачи записи экрана. После перезапуска
    /// окно должно вернуться: иначе человек не видит, что разрешение применилось.
    private static let reopenKey = "mrdi.setupReopen"
    private var isTerminating = false

    private var window: NSWindow?
    private let model = SetupModel()
    private var timer: Timer?
    private var lookupObserver: NSObjectProtocol?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationWillTerminate() }
        }
    }

    /// Нужно ли показать окно при запуске: настройку ещё не прошли,
    /// без главного разрешения приложение не сможет работать,
    /// или его закрыли посреди настройки ради применения разрешения.
    static var isNeeded: Bool {
        let defaults = UserDefaults.standard
        return !defaults.bool(forKey: doneKey)
            || !SelectionCapture.isTrusted
            || defaults.bool(forKey: reopenKey)
    }

    private func applicationWillTerminate() {
        isTerminating = true
        if window?.isVisible == true {
            UserDefaults.standard.set(true, forKey: Self.reopenKey)
        }
    }

    func show() {
        HUDController.shared.hide()
        UserDefaults.standard.removeObject(forKey: Self.reopenKey)
        model.refresh()

        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SetupView(model: model)))
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.title = "Mr.Di."
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        startWatching()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        stopWatching()
        // при выходе из приложения окно тоже закрывается — это не «готово»,
        // а перезапуск посреди настройки
        if isTerminating {
            UserDefaults.standard.set(true, forKey: Self.reopenKey)
            return
        }
        // закрыли крестиком, но главное уже работает — это тоже «готово».
        // Решаем на следующем витке: если окно закрылось из-за выхода
        // из приложения, сюда уже не дойдёт, и после перезапуска окно вернётся
        UserDefaults.standard.set(true, forKey: Self.reopenKey)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isTerminating else { return }
            UserDefaults.standard.removeObject(forKey: Self.reopenKey)
            if SelectionCapture.isTrusted {
                UserDefaults.standard.set(true, forKey: Self.doneKey)
            }
        }
    }

    private func startWatching() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if lookupObserver == nil {
            lookupObserver = NotificationCenter.default.addObserver(
                forName: .mrdiLookupSucceeded, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.triedLookup = true }
            }
        }
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let wasTrusted = model.accessibility
        model.refresh()
        // доступ только что выдали в Системных настройках — возвращаем человека
        // сюда, к следующему шагу, а не оставляем искать окно
        if !wasTrusted, model.accessibility {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    static func resetPermission(_ service: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", service, Bundle.main.bundleIdentifier ?? "com.mrdi.app"]
        try? task.run()
        task.waitUntilExit()
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Запись экрана macOS применяет только к новому процессу.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Вью

struct SetupView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject private var hotkeys = HotkeySettings.shared

    private var lookupKey: String { hotkeys.shortcut(for: .lookupSelection).display }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header

            section("Главное") {
                PermissionRow(
                    done: model.accessibility,
                    title: "Универсальный доступ",
                    detail: model.accessibility
                        ? "Готово: приложение видит выделенный текст."
                        : model.askedAccessibility
                            ? "Включите переключатель напротив Mr.Di. в Системных настройках — галочка здесь появится сама."
                            : "Чтобы читать выделенный текст в любом приложении. Без этого перевод не работает.",
                    button: model.askedAccessibility ? "Открыть настройки" : "Разрешить",
                    prominent: true,
                    action: model.requestAccessibility)
                if model.askedAccessibility, !model.accessibility {
                    StaleHint(action: model.resetAccessibility)
                }
            }

            section("Попробуйте") { tryIt }
                .opacity(model.accessibility ? 1 : 0.45)
                .disabled(!model.accessibility)

            section("По желанию") {
                VStack(spacing: 12) {
                    PermissionRow(
                        done: model.screen,
                        title: "Запись экрана",
                        detail: "Для текста, который нельзя выделить: видео, картинки, субтитры — и для системного звука.",
                        button: model.askedScreen ? "Открыть настройки" : "Разрешить",
                        action: model.requestScreen)
                    if model.askedScreen, !model.screen {
                        HStack {
                            Text("Только что включили? macOS применит разрешение после перезапуска.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Перезапустить") { SetupWindow.relaunch() }
                                .controlSize(.small)
                        }
                        .padding(.leading, 30)
                        StaleHint(action: model.resetScreen)
                    }
                    PermissionRow(
                        done: model.microphone,
                        title: "Микрофон и распознавание речи",
                        detail: "Чтобы сказать слово голосом, если не знаете, как оно пишется. Речь разбирается на устройстве.",
                        button: model.microphoneDenied ? "Открыть настройки" : "Разрешить",
                        action: model.requestMicrophone)
                    HStack(alignment: .top, spacing: 12) {
                        StatusIcon(done: model.loginItem)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Запускать при входе").font(.system(size: 13, weight: .medium))
                            Text(loginDetail)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(get: { model.loginItem }, set: { model.setLoginItem($0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(!LoginItem.isInstalled)
                    }
                }
            }

            footer
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 22)
        .frame(width: 560)
    }

    private var loginDetail: String {
        if model.loginNeedsApproval {
            return "Выключен в Системных настройках → Основные → Объекты входа. Щёлкните переключатель — откроется этот раздел."
        }
        if !LoginItem.isInstalled {
            return "Заработает, когда приложение будет лежать в папке «Программы»."
        }
        return "Включён сам: после перезагрузки перевод работает сразу, запускать ничего не нужно."
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.accessibility ? "Mr.Di. готов к работе" : "Mr.Di. почти готов")
                    .font(.system(size: 20, weight: .semibold))
                HStack(spacing: 4) {
                    Text("Живёт в меню-баре — значок")
                    Image(systemName: "character.book.closed.fill")
                    Text("справа вверху.")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Дважды щёлкните по слову **scrutinize** и нажмите **\(lookupKey)**:")
                .font(.system(size: 12))
            SampleText(text: "The committee will scrutinize every proposal before the final vote.")
                .frame(height: 22)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            if model.triedLookup {
                Label("Работает! В подсказке ⏎ добавит слово в словарь, ␛ закроет её.",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            } else {
                Text("Так же — в браузере, PDF, почте и где угодно ещё.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            HStack(spacing: 6) {
                ForEach([HotkeyAction.screenRegion, .voiceEnglish, .listenBack, .openDictionary], id: \.self) { action in
                    KeyChip(key: hotkeys.shortcut(for: action).display, label: shortLabel(action))
                }
            }
            HStack {
                Text("Это окно всегда можно открыть из меню-бара: «Как пользоваться».")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button("Готово") { SetupWindow.shared.finish() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(!model.accessibility)
            }
        }
    }

    private func shortLabel(_ action: HotkeyAction) -> String {
        switch action {
        case .screenRegion: return "текст с экрана"
        case .voiceEnglish: return "голосом"
        case .listenBack: return "что прозвучало"
        case .openDictionary: return "словарь"
        default: return action.title
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }
}

private struct PermissionRow: View {
    let done: Bool
    let title: String
    let detail: String
    let button: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusIcon(done: done)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !done {
                if prominent {
                    Button(button, action: action).buttonStyle(.borderedProminent)
                } else {
                    Button(button, action: action)
                }
            }
        }
    }
}

/// Переключатель от прошлой версии выглядит включённым, но не работает —
/// самая запутанная ситуация, поэтому выход из неё прямо здесь, одной кнопкой.
private struct StaleHint: View {
    let action: () -> Void

    var body: some View {
        HStack {
            Text("Переключатель включён давно, а галочки нет? Так бывает после обновления.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Сбросить и разрешить заново", action: action)
                .controlSize(.small)
        }
        .padding(.leading, 30)
    }
}

private struct StatusIcon: View {
    let done: Bool

    var body: some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
            .font(.system(size: 18))
            .foregroundStyle(done ? Color.green : Color.secondary)
            .frame(width: 18)
            .contentTransition(.symbolEffect(.replace))
    }
}

private struct KeyChip: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}

/// Настоящее текстовое поле AppKit, а не SwiftUI-текст: его выделение видно через
/// Accessibility так же, как в любом другом приложении — проба честная.
private struct SampleText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isVerticallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.font = .systemFont(ofSize: 15)
        view.textColor = .labelColor
        view.string = text
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {}
}
