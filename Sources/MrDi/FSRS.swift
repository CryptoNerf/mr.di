import Foundation

enum Rating: Int, CaseIterable, Identifiable {
    case again = 1, hard = 2, good = 3, easy = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .again: return "Забыл"
        case .hard: return "Трудно"
        case .good: return "Помню"
        case .easy: return "Легко"
        }
    }
}

struct CardState {
    var stability: Double
    var difficulty: Double
    var due: Date
    var lastReview: Date?
    var reps: Int
    var lapses: Int
}

/// FSRS 4.5 — алгоритм интервальных повторений, который считает не «через сколько дней»,
/// а два свойства памяти: стабильность (как долго держится) и сложность (насколько тяжело даётся).
/// Интервал выводится из них так, чтобы к моменту показа вероятность вспомнить была ~90%.
enum FSRS {
    /// Веса по умолчанию, подобранные на большом корпусе повторений.
    private static let w: [Double] = [
        0.4872, 1.4003, 3.7145, 13.8206, 5.1618, 1.2298, 0.8975, 0.0310, 1.6474,
        0.1367, 1.0461, 2.1072, 0.0793, 0.3246, 1.5870, 0.2272, 2.8755
    ]

    private static let decay = -0.5
    private static let factor = 19.0 / 81.0
    static let requestRetention = 0.9
    private static let maximumIntervalDays = 365.0 * 5
    private static let againDelay: TimeInterval = 5 * 60   // забытое слово вернётся в этой же сессии

    // MARK: - Публичный интерфейс

    static func schedule(_ card: CardState?, rating: Rating, now: Date = Date()) -> CardState {
        guard let card, let lastReview = card.lastReview else {
            return initialCard(rating: rating, now: now)
        }

        let elapsedDays = max(0, now.timeIntervalSince(lastReview) / 86_400)
        let retrievability = retrievability(elapsedDays: elapsedDays, stability: card.stability)

        let difficulty = nextDifficulty(card.difficulty, rating: rating)
        let stability: Double = rating == .again
            ? forgetStability(difficulty: card.difficulty, stability: card.stability, retrievability: retrievability)
            : recallStability(difficulty: card.difficulty, stability: card.stability,
                              retrievability: retrievability, rating: rating)

        return CardState(
            stability: stability,
            difficulty: difficulty,
            due: due(from: stability, rating: rating, now: now),
            lastReview: now,
            reps: card.reps + 1,
            lapses: card.lapses + (rating == .again ? 1 : 0)
        )
    }

    /// Что будет, если нажать каждую из кнопок — показывается прямо на них.
    static func preview(_ card: CardState?, now: Date = Date()) -> [Rating: TimeInterval] {
        var result: [Rating: TimeInterval] = [:]
        for rating in Rating.allCases {
            let scheduled = schedule(card, rating: rating, now: now)
            result[rating] = scheduled.due.timeIntervalSince(now)
        }
        return result
    }

    static func describe(_ interval: TimeInterval) -> String {
        let days = interval / 86_400
        if days < 1 { return "\(max(1, Int(interval / 60))) мин" }
        if days < 30 { return "\(Int(days.rounded())) дн" }
        if days < 365 { return "\(Int((days / 30).rounded())) мес" }
        return String(format: "%.1f г", days / 365)
    }

    // MARK: - Внутренние формулы

    private static func initialCard(rating: Rating, now: Date) -> CardState {
        let stability = max(0.1, w[rating.rawValue - 1])
        let difficulty = clampDifficulty(initialDifficulty(rating))
        return CardState(
            stability: stability,
            difficulty: difficulty,
            due: due(from: stability, rating: rating, now: now),
            lastReview: now,
            reps: 1,
            lapses: rating == .again ? 1 : 0
        )
    }

    private static func initialDifficulty(_ rating: Rating) -> Double {
        w[4] - Double(rating.rawValue - 3) * w[5]
    }

    private static func nextDifficulty(_ difficulty: Double, rating: Rating) -> Double {
        let shifted = difficulty - w[6] * Double(rating.rawValue - 3)
        // притяжение к «лёгкой» сложности: без него карточки постепенно уползают в максимум
        let reverted = w[7] * initialDifficulty(.easy) + (1 - w[7]) * shifted
        return clampDifficulty(reverted)
    }

    private static func retrievability(elapsedDays: Double, stability: Double) -> Double {
        pow(1 + factor * elapsedDays / max(stability, 0.1), decay)
    }

    private static func recallStability(difficulty: Double, stability: Double,
                                        retrievability: Double, rating: Rating) -> Double {
        let hardPenalty = rating == .hard ? w[15] : 1
        let easyBonus = rating == .easy ? w[16] : 1
        let growth = exp(w[8]) * (11 - difficulty) * pow(stability, -w[9])
            * (exp((1 - retrievability) * w[10]) - 1) * hardPenalty * easyBonus
        return stability * (1 + growth)
    }

    private static func forgetStability(difficulty: Double, stability: Double,
                                        retrievability: Double) -> Double {
        w[11] * pow(difficulty, -w[12]) * (pow(stability + 1, w[13]) - 1)
            * exp((1 - retrievability) * w[14])
    }

    private static func due(from stability: Double, rating: Rating, now: Date) -> Date {
        guard rating != .again else { return now.addingTimeInterval(againDelay) }
        return now.addingTimeInterval(intervalDays(stability) * 86_400)
    }

    /// Интервал, на котором вероятность вспомнить упадёт ровно до requestRetention.
    private static func intervalDays(_ stability: Double) -> Double {
        let raw = stability / factor * (pow(requestRetention, 1 / decay) - 1)
        return min(max(raw.rounded(), 1), maximumIntervalDays)
    }

    private static func clampDifficulty(_ value: Double) -> Double {
        min(max(value, 1), 10)
    }
}
