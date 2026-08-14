import ServiceManagement

/// Автозапуск при входе в систему.
/// Утилита в меню-баре бесполезна, если её нужно вспоминать и запускать руками:
/// незнакомое слово попадается внезапно, и приложение к этому моменту уже должно работать.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("[mrdi] не удалось изменить автозапуск: \(error.localizedDescription)")
            return false
        }
    }
}
