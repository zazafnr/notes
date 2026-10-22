import Foundation

/// Was Claude in diesem Monat schon gekostet hat (in US-Dollar, so rechnet Anthropic ab).
struct ClaudeUsageLedger: Codable, Equatable, Sendable {
    /// z. B. »2026-10«
    var month: String = ""
    /// Ausgaben dieses Monats ohne den heutigen Tag.
    var spentBeforeToday: Double = 0
    /// z. B. »2026-10-22«
    var day: String = ""
    var spentToday: Double = 0
    var requestsThisMonth: Int = 0

    var spentThisMonth: Double { spentBeforeToday + spentToday }
}

/// Verteilt das Monatsbudget gleichmäßig auf die restlichen Tage.
/// Nicht verbrauchtes Geld eines Tages verteilt sich auf die folgenden Tage,
/// mehr als das Monatsbudget wird nie freigegeben (höchstens eine Anfrage darüber).
struct ClaudeBudget: Equatable, Sendable {
    var monthlyBudget: Double
    var ledger: ClaudeUsageLedger
    var calendar: Calendar

    init(monthlyBudget: Double, ledger: ClaudeUsageLedger, calendar: Calendar = .current) {
        self.monthlyBudget = monthlyBudget
        self.ledger = ledger
        self.calendar = calendar
    }

    static func monthKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Stellt die Zähler auf den Tag von `date` um (neuer Tag oder neuer Monat).
    mutating func roll(to date: Date) {
        let month = Self.monthKey(date, calendar: calendar)
        let day = Self.dayKey(date, calendar: calendar)
        if ledger.month != month {
            ledger = ClaudeUsageLedger(month: month, day: day)
        } else if ledger.day != day {
            ledger.spentBeforeToday += ledger.spentToday
            ledger.spentToday = 0
            ledger.day = day
        }
    }

    func rolled(to date: Date) -> ClaudeBudget {
        var copy = self
        copy.roll(to: date)
        return copy
    }

    /// Restliche Tage im Monat, heute mitgezählt.
    func remainingDays(at date: Date) -> Int {
        guard let range = calendar.range(of: .day, in: .month, for: date) else { return 1 }
        let today = calendar.component(.day, from: date)
        return max(range.count - today + 1, 1)
    }

    /// Wie viel heute insgesamt ausgegeben werden darf.
    func dailyAllowance(at date: Date) -> Double {
        let b = rolled(to: date)
        return max(0, (monthlyBudget - b.ledger.spentBeforeToday) / Double(b.remainingDays(at: date)))
    }

    func remainingToday(at date: Date) -> Double {
        max(0, dailyAllowance(at: date) - rolled(to: date).ledger.spentToday)
    }

    /// Durchschnittskosten einer Anfrage (geschätzt, bis es echte Werte gibt).
    func averageCost(model: String) -> Double {
        let l = ledger
        guard l.requestsThisMonth >= 3, l.spentThisMonth > 0 else { return ClaudePricing.typicalCost(model: model) }
        return l.spentThisMonth / Double(l.requestsThisMonth)
    }

    /// Ungefähre Zahl der Claude-Anfragen, die heute noch gehen.
    func requestsLeftToday(at date: Date, model: String) -> Int {
        Int((remainingToday(at: date) / averageCost(model: model)).rounded(.down))
    }

    /// Ungefähre Zahl der Anfragen pro Tag bei vollem Monatsbudget.
    static func requestsPerDay(monthlyBudget: Double, model: String, daysInMonth: Int = 30) -> Int {
        Int((monthlyBudget / Double(daysInMonth) / ClaudePricing.typicalCost(model: model)).rounded(.down))
    }

    /// Darf die nächste Anfrage noch über Claude laufen?
    func canUseClaude(at date: Date, model: String) -> Bool {
        let rest = remainingToday(at: date)
        return rest > 0 && rest >= averageCost(model: model) * 0.5
    }

    mutating func record(cost: Double, at date: Date) {
        roll(to: date)
        ledger.spentToday += max(cost, 0)
        ledger.requestsThisMonth += 1
    }
}
