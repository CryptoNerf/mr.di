import AppKit
import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
    case noPermission
    case displayNotFound
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .noPermission:
            return "Нужен доступ: Системные настройки → Конфиденциальность и безопасность → Запись экрана"
        case .displayNotFound: return "Не удалось определить экран"
        case .captureFailed: return "Не удалось снять область экрана"
        }
    }
}

enum ScreenCapture {

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Список экранов дорого запрашивать в момент захвата (~100 мс),
    /// поэтому держим его наготове и обновляем при смене конфигурации мониторов.
    private static var cachedContent: SCShareableContent?

    static func prewarm() {
        Task { cachedContent = try? await SCShareableContent.current }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            Task { cachedContent = try? await SCShareableContent.current }
        }
    }

    static func capture(rect: NSRect, on screen: NSScreen, upscale: CGFloat = 2) async throws -> CGImage {
        guard hasPermission else { throw ScreenCaptureError.noPermission }

        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { throw ScreenCaptureError.displayNotFound }
        let displayID = CGDirectDisplayID(number.uint32Value)

        // список окон берём свежий: он нужен, чтобы вычесть из снимка собственные окна,
        // а они появляются и исчезают как раз между запросами
        let content = try await SCShareableContent.current
        cachedContent = content
        guard let display = content.displays.first(where: { $0.displayID == displayID })
        else { throw ScreenCaptureError.displayNotFound }

        // глобальные координаты AppKit (начало внизу слева) → координаты дисплея (вверху слева)
        let local = CGRect(x: rect.minX - screen.frame.minX,
                           y: screen.frame.maxY - rect.maxY,
                           width: rect.width, height: rect.height)

        let config = SCStreamConfiguration()
        config.sourceRect = local
        // мелкий текст субтитров распознаётся заметно лучше, если снять его с запасом
        let factor = screen.backingScaleFactor * upscale
        config.width = max(16, Int(local.width * factor))
        config.height = max(16, Int(local.height * factor))
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreGlobalClipDisplay = true
        config.ignoreShadowsDisplay = true

        // собственные окна не должны попасть в кадр: открытый словарь поверх нужной
        // области распознался бы вместо неё
        let ownWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
