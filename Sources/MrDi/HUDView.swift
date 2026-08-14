import SwiftUI

@MainActor
final class HUDModel: ObservableObject {
    enum State {
        case loading(String)
        case result(LookupResult)
        case transcript(String)
        case listening(String)
        case error(String)
    }

    @Published var state: State = .loading("")
    @Published var alreadySaved = false
    @Published var justSaved = false
    @Published var seenCount = 0
    @Published var listenHint = ""
}

/// Панель всплывает поверх произвольного контента — чаще всего поверх тёмного видео.
/// Поэтому она всегда тёмная и с собственными цветами, а не системными семантическими:
/// иначе в светлой теме получается серый текст на сером фоне.
private enum HUDColor {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.66)
    static let tertiary = Color.white.opacity(0.42)
    static let accent = Color(red: 1.0, green: 0.72, blue: 0.35)
}

struct HUDSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel
    var onSize: (CGSize) -> Void = { _ in }
    var onWordTap: (String) -> Void = { _ in }

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
                .padding(16)
                .frame(width: 380, alignment: .leading)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.62))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: HUDSizeKey.self, value: proxy.size)
                    }
                }

            // невидимая подложка, которая держит сессию перевода прогретой
            TranslationHost()
        }
        .padding(10)
        .environment(\.colorScheme, .dark)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "mrdiword",
                  let word = url.host()?.removingPercentEncoding else { return .systemAction }
            onWordTap(word)
            return .handled
        })
        .onPreferenceChange(HUDSizeKey.self) { size in onSize(size) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading(let word):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(word.isEmpty ? "Читаю выделение…" : word)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(HUDColor.secondary)
                    .lineLimit(1)
            }

        case .listening(let partial):
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                    Text(partial.isEmpty ? "Говорите…" : partial)
                        .font(.system(size: partial.isEmpty ? 14 : 17, weight: .medium))
                        .foregroundStyle(partial.isEmpty ? HUDColor.secondary : HUDColor.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(model.listenHint)
                    .font(.system(size: 11))
                    .foregroundStyle(HUDColor.tertiary)
            }

        case .transcript(let text):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11))
                        .foregroundStyle(HUDColor.accent)
                    Text("Прозвучало только что")
                        .font(.system(size: 11))
                        .foregroundStyle(HUDColor.secondary)
                }
                Text(clickableWords(text))
                    .font(.system(size: 15))
                    .foregroundStyle(HUDColor.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
                HStack(spacing: 10) {
                    Text("Нажмите на незнакомое слово")
                        .font(.system(size: 11)).foregroundStyle(HUDColor.tertiary)
                    Spacer(minLength: 4)
                    key("⌥A", "ещё раз")
                    key("␛", "закрыть")
                }
                .padding(.top, 2)
            }

        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(HUDColor.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("␛ закрыть").font(.system(size: 11)).foregroundStyle(HUDColor.tertiary)
            }

        case .result(let r):
            VStack(alignment: .leading, spacing: 10) {
                header(r)
                Text(r.translation)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(HUDColor.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !r.senses.isEmpty {
                    Divider().overlay(Color.white.opacity(0.15))
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(r.senses.prefix(3).enumerated()), id: \.offset) { _, sense in
                            senseRow(sense)
                        }
                    }
                }

                if let ctx = r.context, !ctx.isEmpty {
                    Divider().overlay(Color.white.opacity(0.15))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(highlighted(ctx, word: r.surface))
                            .font(.system(size: 11))
                            .foregroundStyle(HUDColor.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        if let ct = r.contextTranslation {
                            Text(ct)
                                .font(.system(size: 11))
                                .foregroundStyle(HUDColor.tertiary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                footer
            }
        }
    }

    private func senseRow(_ sense: Sense) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(sense.pos)
                .font(.system(size: 9))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(HUDColor.tertiary)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(sense.definition)
                    .font(.system(size: 11))
                    .foregroundStyle(HUDColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let example = sense.example, !example.isEmpty {
                    Text(example)
                        .font(.system(size: 11).italic())
                        .foregroundStyle(HUDColor.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func header(_ r: LookupResult) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(r.surface)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(HUDColor.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if r.lemma.lowercased() != r.surface.lowercased() {
                Text("→ \(r.lemma)").font(.system(size: 12)).foregroundStyle(HUDColor.tertiary)
            }
            if let ipa = r.ipa, !ipa.isEmpty {
                Text(ipa)
                    .font(.system(size: 12, design: .serif))
                    .foregroundStyle(HUDColor.tertiary)
            }
            if let pos = r.pos {
                Text(pos)
                    .font(.system(size: 10))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.white.opacity(0.14), in: Capsule())
                    .foregroundStyle(HUDColor.secondary)
            }
            Spacer(minLength: 4)
            if model.seenCount > 1 {
                Text("\(model.seenCount)-й раз")
                    .font(.system(size: 10))
                    .foregroundStyle(HUDColor.accent)
                    .fixedSize()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.justSaved {
                Label("В словаре", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(.green)
            } else if model.alreadySaved {
                Label("Уже в словаре", systemImage: "checkmark")
                    .font(.system(size: 11)).foregroundStyle(HUDColor.secondary)
            } else {
                key("⏎", "добавить")
            }
            Spacer(minLength: 4)
            key("P", "произнести")
            key("␛", "закрыть")
        }
        .padding(.top, 2)
    }

    private func key(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(symbol)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(HUDColor.secondary)
            Text(label).font(.system(size: 11)).foregroundStyle(HUDColor.tertiary)
        }
    }

    /// Каждое слово расшифровки — ссылка: клик по нему открывает обычный перевод слова,
    /// а вся реплика уходит в контекст. Это дешевле, чем рисовать сетку кнопок,
    /// и текст остаётся текстом с нормальными переносами.
    private func clickableWords(_ text: String) -> AttributedString {
        var result = AttributedString()
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false)

        for (index, token) in tokens.enumerated() {
            var piece = AttributedString(String(token))
            let bare = token.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
            if bare.rangeOfCharacter(from: .letters) != nil,
               let encoded = bare.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
               let url = URL(string: "mrdiword://" + encoded) {
                piece.link = url
                piece.foregroundColor = HUDColor.primary
                piece.underlineStyle = Text.LineStyle(pattern: .dot, color: .white.opacity(0.35))
            }
            result += piece
            if index < tokens.count - 1 { result += AttributedString(" ") }
        }
        return result
    }

    /// Подсвечиваем искомое слово внутри предложения — глаз находит его мгновенно.
    private func highlighted(_ sentence: String, word: String) -> AttributedString {
        var attributed = AttributedString(sentence)
        if let range = attributed.range(of: word, options: [.caseInsensitive]) {
            attributed[range].foregroundColor = HUDColor.primary
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }
}
