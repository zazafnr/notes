import Foundation

/// Eine von Stella gelöste HÜ, die ins Heft geschrieben werden soll.
struct StellaEntry: Codable, Identifiable, Equatable {
    var id: String
    var subject: String?
    var title: String
    var page: String?
    var exercises: String?
    var due: String?
    /// Heft-Text: __unterstrichen__, ==doppelt unterstrichen== (gleiches Format wie die KI-Antworten der App).
    var text: String
}

/// Reine Logik der Stella-Anbindung (ohne Oberfläche, damit testbar).
enum StellaLogic {
    /// »stella.example.at« → https://stella.example.at (ohne Schrägstrich am Ende).
    static func normalizedServer(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host, host.contains(".") || host == "localhost" else { return nil }
        return url
    }

    /// Klein, ohne Akzente/Umlaute-Punkte: »Französisch« → »franzosisch«.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_AT"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Andere Namen, unter denen ein Fach in der App heißen kann.
    static let aliases: [[String]] = [
        ["mathe", "mathematik", "math", "ma", "m"],
        ["deutsch", "de", "d"],
        ["englisch", "english", "engl", "en", "e"],
        ["franzosisch", "franz", "frz", "francais", "french", "f"],
        ["latein", "lat", "l"],
        ["spanisch", "spa", "espanol"],
        ["italienisch", "ita", "italiano"],
        ["biologie", "bio", "bu"],
        ["geschichte", "gsk", "gs"],
        ["geografie", "geographie", "geo", "gwk"],
        ["physik", "ph"],
        ["chemie", "ch"],
        ["informatik", "info", "inf"],
        ["psychologie & philosophie", "pup", "psychologie", "philosophie"],
        ["religion", "reli", "rk"],
        ["musik", "mu", "me"],
        ["kunst", "be", "bildnerische erziehung"],
    ]

    /// Gehören die beiden Namen zum selben Fach? (»Französisch« ~ »Franz«, »Mathe« ~ »Mathe-Heft«)
    static func sameSubject(_ a: String, _ b: String) -> Bool {
        let x = fold(a), y = fold(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        for group in aliases where group.contains(x) && group.contains(y) { return true }
        let separators: [Character] = [" ", "-", "_", ":", "("]
        func starts(_ long: String, with short: String) -> Bool {
            long.count > short.count && long.hasPrefix(short) && separators.contains(long[long.index(long.startIndex, offsetBy: short.count)])
        }
        if starts(x, with: y) || starts(y, with: x) { return true }
        // »Franz-Heft« ~ »Französisch«: erstes Wort über die Aliasse vergleichen
        let firstX = String(x.split(whereSeparator: { separators.contains($0) }).first ?? "")
        let firstY = String(y.split(whereSeparator: { separators.contains($0) }).first ?? "")
        return (firstX != x || firstY != y) && !firstX.isEmpty && !firstY.isEmpty && sameSubject(firstX, firstY)
    }

    /// Passendes Heft für ein Fach: erst über die Fach-Zuordnung, sonst über den Titel; das zuletzt benutzte gewinnt.
    static func notebookID(forSubject subject: String, subjects: [Subject], notebooks: [Notebook]) -> UUID? {
        let subjectIDs = Set(subjects.filter { sameSubject($0.name, subject) }.map(\.id))
        let candidates = notebooks.filter { nb in
            (nb.subjectID.map { subjectIDs.contains($0) } ?? false) || sameSubject(nb.title, subject)
        }
        return candidates.max { ($0.opened ?? $0.modified) < ($1.opened ?? $1.modified) }?.id
    }

    /// Text fürs Heft; ohne Kopfzeile von Stella eine aus dem Titel.
    static func notebookText(for entry: StellaEntry) -> String {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("__") ? text : "__\(entry.title)__\n\n\(text)"
    }

    /// Fehlermeldung aus einer Stella-Antwort ({"error": "…"}).
    static func errorMessage(from data: Data, status: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let message = json["error"] as? String {
            return message
        }
        return "Stella antwortet nicht richtig (Fehler \(status))."
    }
}
