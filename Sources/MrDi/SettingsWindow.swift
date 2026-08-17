import AppKit
import SwiftUI

@MainActor
final class ShortcutSettingsModel: ObservableObject {
    @Published var recording: HotkeyAction?
    @Published var warning: String?

    func startRecording(_ action: HotkeyAction) {
        recording = recording == action ? nil : action
        warning = nil
    }

    func apply(_ shortcut: Shortcut, to action: HotkeyAction) {
        // одно сочетание на два действия означало бы, что одно из них просто не сработает
        if let conflict = HotkeySettings.shared.conflict(with: shortcut, excluding: action) {
            warning = "\(shortcut.display) уже занято: «\(conflict.title)»"
            return
        }
        HotkeySettings.shared.set(shortcut, for: action)
        recording = nil
        warning = nil
    }
}

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    private let model = ShortcutSettingsModel()
    private var monitor: Any?

    private init() {}

    func show() {
        model.recording = nil
        model.warning = nil

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Сочетания клавиш"
        w.center()
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView(model: model))
        window = w
        installMonitor()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Пока идёт запись сочетания, нажатие ловится здесь и не доходит до интерфейса:
    /// иначе пробел нажимал бы кнопку, а ⌘W закрывал окно.
    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.model.recording else { return event }

            if event.keyCode == UInt16(KeyCode.escape) {
                self.model.recording = nil
                return nil
            }
            if let shortcut = Shortcut(event: event) {
                self.model.apply(shortcut, to: action)
            } else {
                self.model.warning = "Нужен хотя бы один модификатор: ⌥, ⌃, ⌘ или ⇧"
            }
            return nil
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: ShortcutSettingsModel
    @ObservedObject private var settings = HotkeySettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(HotkeyAction.allCases) { action in
                        row(action)
                        if action != HotkeyAction.allCases.last { Divider().opacity(0.4) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 380)
    }

    private func row(_ action: HotkeyAction) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title).font(.system(size: 13))
                if let hint = action.hint {
                    Text(hint).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)

            Button {
                model.startRecording(action)
            } label: {
                Text(model.recording == action ? "Нажмите сочетание…" : settings.shortcut(for: action).display)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(width: 150)
            }
            .controlSize(.large)
            .tint(model.recording == action ? .accentColor : nil)

            Button {
                HotkeySettings.shared.reset(action)
            } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Вернуть сочетание по умолчанию")
        }
        .padding(.vertical, 7)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else {
                Text("Клавиши внутри подсказки — ⏎ добавить, P произнести, ␛ закрыть — не меняются: они работают только пока она открыта.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Сбросить всё") { HotkeySettings.shared.resetAll() }
                    .controlSize(.small)
            }
        }
        .padding(12)
    }
}
