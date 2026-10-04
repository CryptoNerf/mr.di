import Foundation
import ServiceManagement

/// Автозапуск при входе в систему.
/// Утилита в меню-баре бесполезна, если её нужно вспоминать и запускать руками:
/// незнакомое слово попадается внезапно, и приложение к этому моменту уже должно работать.
/// Поэтому автозапуск включён по умолчанию и сам восстанавливается, если пропал, —
/// выключить его может только сам пользователь.
enum LoginItem {
    private static let optOutKey = "mrdi.loginOptOut"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Пользователь выключил автозапуск в Системных настройках → Объекты входа:
    /// включить его обратно может только он сам, программно это запрещено.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Регистрировать можно только копию из «Программ»: приложение из «Загрузок»
    /// или со смонтированного образа исчезнет, а запись автозапуска останется.
    static var isInstalled: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    /// Вызывается на каждом запуске. Регистрация может слететь после обновления
    /// приложения или сброса настроек — тогда возвращаем её, пока пользователь
    /// сам не отказался от автозапуска.
    static func ensureEnabled() {
        guard isInstalled,
              !UserDefaults.standard.bool(forKey: optOutKey),
              SMAppService.mainApp.status == .notRegistered || SMAppService.mainApp.status == .notFound
        else { return }
        set(true)
    }

    /// Переключатель в меню или окне настройки: выбор пользователя запоминаем,
    /// чтобы ensureEnabled() не включал автозапуск обратно против его воли.
    @discardableResult
    static func userSet(_ enabled: Bool) -> Bool {
        UserDefaults.standard.set(!enabled, forKey: optOutKey)
        if enabled, needsApproval {
            SMAppService.openSystemSettingsLoginItems()
            return false
        }
        return set(enabled)
    }

    @discardableResult
    private static func set(_ enabled: Bool) -> Bool {
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
