import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum LibraryMode: String, CaseIterable {
    case dictionary, review

    var title: String {
        switch self {
        case .dictionary: return "Словарь"
        case .review: return "Повторение"
        }
    }
}

@MainActor
final class WordListModel: ObservableObject {
    @Published var words: [WordEntry] = []
    @Published var query = ""
    @Published var mode: LibraryMode = .dictionary
    @Published var dueCount = 0

    var filtered: [WordEntry] {
        guard !query.isEmpty else { return words }
        let q = query.lowercased()
        return words.filter { $0.lemma.lowercased().contains(q) || $0.translation.lowercased().contains(q) }
    }

    func reload() {
        words = Store.shared.allWords()
        dueCount = Store.shared.dueCount()
    }

    func delete(_ entry: WordEntry) {
        Store.shared.delete(id: entry.id)
        reload()
    }
}

@MainActor
final class WordListWindow {
    static let shared = WordListWindow()
    private var window: NSWindow?
    private let model = WordListModel()
    private let reviewModel = ReviewModel()

    private init() {}

    func show(mode: LibraryMode? = nil) {
        model.reload()
        if let mode { model.mode = mode }
        if model.mode == .review { reviewModel.load() }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Словарь"
        w.center()
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: WordListView(model: model, review: reviewModel))
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshIfOpen() {
        guard window?.isVisible == true else { return }
        model.reload()
    }

    var dueCount: Int { Store.shared.dueCount() }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mrdi.csv"
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // формат, который Anki импортирует напрямую: слово;перевод;контекст
        let rows = Store.shared.allWords().map { entry -> String in
            [entry.lemma, entry.translation, entry.ipa ?? "",
             entry.senses.first?.definition ?? "", entry.context ?? ""]
                .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                .joined(separator: ",")
        }
        try? (["\"word\",\"translation\",\"ipa\",\"definition\",\"context\""] + rows)
            .joined(separator: "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }
}

struct WordListView: View {
    @ObservedObject var model: WordListModel
    @ObservedObject var review: ReviewModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.words.isEmpty {
                modePicker
                Divider()
            }
            switch model.mode {
            case .dictionary:
                if model.words.isEmpty { emptyState } else { list }
            case .review:
                ReviewView(model: review)
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 500, minHeight: 620)
        .onAppear { model.reload() }
    }

    private var modePicker: some View {
        HStack {
            Picker("", selection: $model.mode) {
                ForEach(LibraryMode.allCases, id: \.self) { mode in
                    Text(mode == .review && model.dueCount > 0
                         ? "\(mode.title) · \(model.dueCount)"
                         : mode.title)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .onChange(of: model.mode) { _, newValue in
            if newValue == .review { review.load() } else { model.reload() }
        }
    }

    private var list: some View {
        List {
            ForEach(model.filtered) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.lemma).font(.system(size: 14, weight: .semibold))
                        if let ipa = entry.ipa, !ipa.isEmpty {
                            Text(ipa).font(.system(size: 11, design: .serif)).foregroundStyle(.tertiary)
                        }
                        if let pos = entry.pos {
                            Text(pos).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        Button {
                            Speaker.speak(entry.lemma)
                        } label: {
                            Image(systemName: "speaker.wave.2").font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .help("Произнести")
                        Spacer()
                        Text(entry.createdAt, style: .date)
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Text(entry.translation).font(.system(size: 13)).foregroundStyle(.secondary)
                    if let sense = entry.senses.first {
                        Text(sense.definition).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
                    }
                    if let ctx = entry.context {
                        Text(ctx).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
                    }
                }
                .padding(.vertical, 3)
                .contextMenu {
                    Button("Удалить", role: .destructive) { model.delete(entry) }
                }
            }
        }
        .searchable(text: $model.query, prompt: "Поиск по словарю")
    }

    /// Пустой словарь — единственное место, где можно объяснить, как всё работает.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Словарь пока пуст").font(.system(size: 17, weight: .semibold))
                Text("Приложение живёт в меню-баре и вызывается из любого места.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                step("⌥Space", "Выделите английское слово где угодно — в статье, PDF, коде — и нажмите. Перевод появится рядом с курсором, ничего не переключая.")
                step("⌥S", "Текст нельзя выделить — видео, картинка, игра? Обведите его мышью, и он будет распознан прямо с экрана.")
                step("⌥R", "Переснять ту же область ещё раз. Для субтитров: обвели строку один раз, дальше жмёте только ⌥R.")
                step("⌥V", "Скажите английское слово в микрофон — удерживая ⌥V, либо коротко нажав, сказав и нажав ещё раз. Расшифровка видна прямо во время речи.")
                step("⇧⌥V", "То же, но по-русски: скажете «собака» — получите dog. Язык задаётся сочетанием, а не угадывается.")
                step("⌥A", "Услышали слово, но не видите его? Покажет расшифровку последних 15 секунд системного звука — нажмите на незнакомое слово прямо в ней. Включается в меню-баре.")
                step("⏎", "Пока подсказка открыта — слово уходит в этот словарь вместе с предложением, в котором встретилось.")
                step("P", "Пока подсказка открыта — произнести слово вслух.")
                step("␛", "Закрыть подсказку. Клик мышью тоже закрывает.")
                step("⌥D", "Открыть этот словарь из любого места.")
                step("Свои клавиши", "Любое сочетание можно переназначить: меню-бар → «Сочетания клавиш…».")
                step("Автозапуск", "В меню-баре включите «Запускать при входе» — приложение должно уже работать к моменту, когда попадётся незнакомое слово.")
                step("Повторение", "Собранные слова превращаются в карточки: приложение само решает, какое слово и когда показать, чтобы оно осталось в памяти надолго.")
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ key: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(key)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .frame(width: 74, alignment: .center)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text("\(model.words.count) слов").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("⌥Space выделенное · ⌥S экран · ⌥V голос · ⌥A звук · ⏎ добавить")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            Button("Экспорт CSV") { WordListWindow.shared.exportCSV() }
                .controlSize(.small)
                .disabled(model.words.isEmpty)
        }
        .padding(10)
    }
}
