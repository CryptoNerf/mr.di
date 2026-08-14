import SwiftUI

@MainActor
final class ReviewModel: ObservableObject {
    @Published var current: ReviewCard?
    @Published var revealed = false
    @Published var remaining = 0
    @Published var reviewed = 0
    @Published var nextDue: Date?

    private var queue: [ReviewCard] = []

    func load() {
        queue = Store.shared.dueCards(limit: 100)
        reviewed = 0
        nextDue = Store.shared.nextDue()
        advance()
    }

    func reveal() { revealed = true }

    func grade(_ rating: Rating) {
        guard let card = current else { return }
        let state = FSRS.schedule(card.state, rating: rating)
        Store.shared.saveCard(wordID: card.entry.id, state: state)
        reviewed += 1

        // забытое слово возвращается в конец этой же сессии, а не через сутки
        if rating == .again {
            queue.append(ReviewCard(entry: card.entry, state: state))
        }
        nextDue = Store.shared.nextDue()
        advance()
    }

    var previews: [Rating: TimeInterval] {
        FSRS.preview(current?.state)
    }

    private func advance() {
        current = queue.first
        if !queue.isEmpty { queue.removeFirst() }
        remaining = queue.count + (current == nil ? 0 : 1)
        revealed = false
    }
}

struct ReviewView: View {
    @ObservedObject var model: ReviewModel

    var body: some View {
        VStack(spacing: 0) {
            if let card = model.current {
                progress
                Divider()
                cardBody(card)
                Divider()
                ratings
            } else {
                finished
            }
        }
        .onAppear { model.load() }
    }

    private var progress: some View {
        HStack(spacing: 10) {
            Text("Осталось \(model.remaining)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            if model.reviewed > 0 {
                Text("Повторено \(model.reviewed)")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func cardBody(_ card: ReviewCard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(card.entry.lemma)
                        .font(.system(size: 30, weight: .semibold))
                        .textSelection(.enabled)
                    if let ipa = card.entry.ipa, !ipa.isEmpty {
                        Text(ipa).font(.system(size: 14, design: .serif)).foregroundStyle(.secondary)
                    }
                    Button { Speaker.speak(card.entry.lemma) } label: {
                        Image(systemName: "speaker.wave.2")
                    }
                    .buttonStyle(.borderless)
                    .help("Произнести")
                    Spacer()
                    if let pos = card.entry.pos {
                        Text(pos).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }

                // предложение показываем сразу, но со скрытым словом:
                // так вспоминается по смыслу, а не по внешнему виду строки
                if let context = card.entry.context, !context.isEmpty {
                    Text(model.revealed ? context : mask(context, word: card.entry.surface))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.revealed {
                    Divider()
                    Text(card.entry.translation)
                        .font(.system(size: 20, weight: .medium))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(Array(card.entry.senses.prefix(2).enumerated()), id: \.offset) { _, sense in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(sense.pos)  \(sense.definition)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let example = sense.example, !example.isEmpty {
                                Text(example)
                                    .font(.system(size: 12).italic())
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } else {
                    Button("Показать перевод   ␣") { model.reveal() }
                        .controlSize(.large)
                        .keyboardShortcut(.space, modifiers: [])
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var ratings: some View {
        HStack(spacing: 8) {
            if model.revealed {
                ForEach(Rating.allCases) { rating in
                    Button { model.grade(rating) } label: {
                        VStack(spacing: 2) {
                            Text(rating.title).font(.system(size: 12, weight: .medium))
                            Text(FSRS.describe(model.previews[rating] ?? 0))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .keyboardShortcut(KeyEquivalent(Character("\(rating.rawValue)")), modifiers: [])
                }
            } else {
                Text("␣ показать перевод, затем 1–4 — оценка")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(10)
    }

    private var finished: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34)).foregroundStyle(.green)
            Text(model.reviewed > 0 ? "Повторено \(model.reviewed) — на сегодня всё" : "Сейчас нечего повторять")
                .font(.system(size: 15, weight: .medium))
            if let next = model.nextDue {
                Text("Следующее слово — \(next.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("Добавляйте слова через ⌥Space — они появятся здесь")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Button("Проверить ещё раз") { model.load() }
                .controlSize(.small)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func mask(_ sentence: String, word: String) -> String {
        guard !word.isEmpty else { return sentence }
        return sentence.replacingOccurrences(of: word, with: "•••",
                                             options: [.caseInsensitive, .diacriticInsensitive])
    }
}
