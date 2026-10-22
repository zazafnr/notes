import Foundation

enum QuickAction: String, CaseIterable, Identifiable {
    case quick, solve, explain, steps, hint, summarize, write, translate, latinSentence, latinWord

    var id: String { rawValue }

    /// Aktionen, die im Frage-Fenster angeboten werden (Latein-Aktionen nur im Latein-Heft).
    static func available(latin: Bool) -> [QuickAction] {
        let general: [QuickAction] = [.quick, .solve, .explain, .steps, .hint, .summarize, .write, .translate]
        return latin ? [.quick, .latinSentence, .latinWord] + general.dropFirst() : general
    }

    /// Erkennt ein Latein-Heft am Fach oder Titel.
    static func isLatin(_ names: [String?]) -> Bool {
        names.compactMap { $0?.lowercased() }.contains { $0.contains("latein") || $0.contains("latin") }
    }

    var title: String {
        switch self {
        case .quick: return "Nur Antworten"
        case .solve: return "Lösen"
        case .explain: return "Erklären"
        case .steps: return "Schritt für Schritt"
        case .hint: return "Nur Tipp"
        case .summarize: return "Zusammenfassen"
        case .write: return "Text schreiben"
        case .translate: return "Übersetzen"
        case .latinSentence: return "Satz: Übersetzung + Grammatik"
        case .latinWord: return "Wort bestimmen"
        }
    }

    var symbol: String {
        switch self {
        case .quick: return "bolt.fill"
        case .solve: return "checkmark.seal"
        case .explain: return "lightbulb"
        case .steps: return "list.number"
        case .hint: return "questionmark.bubble"
        case .summarize: return "text.redaction"
        case .write: return "pencil.line"
        case .translate: return "character.bubble"
        case .latinSentence: return "text.word.spacing"
        case .latinWord: return "character.magnify"
        }
    }

    /// Hervorgehobene Aktionen (oben, farbig).
    var isProminent: Bool {
        self == .quick || self == .latinSentence || self == .latinWord
    }

    var prompt: String {
        switch self {
        case .quick:
            return """
            Gib NUR die fertigen Antworten bzw. Lösungen für die Aufgaben auf dem Bild, so kurz wie möglich, damit ich sie schnell abschreiben kann.
            Keine Erklärung, keine Einleitung, kein Rechenweg, keine Wiederholung der Aufgabe.
            Format: eine Zeile pro Teilaufgabe, z. B. »1) …«, bei Beschriftungen »Nr. – Begriff«. Ergebnisse fett.
            """
        case .solve:
            return "Löse die Aufgabe auf dem Bild. Zeig kurz den Rechenweg und schreib das Ergebnis fett."
        case .explain:
            return "Erklär mir verständlich, worum es in diesem Ausschnitt geht und wie man so etwas angeht."
        case .steps:
            return "Löse die Aufgabe ausführlich Schritt für Schritt. Nummeriere die Schritte und erklär jeden kurz."
        case .hint:
            return "Verrate nicht die Lösung. Gib mir nur einen hilfreichen Tipp, wie ich selbst auf die Lösung komme."
        case .summarize:
            return "Fasse den Inhalt des Ausschnitts kurz und übersichtlich in Stichpunkten zusammen."
        case .write:
            return "Schreib den Text, den die Aufgabe auf dem Bild verlangt. Passend zu meiner Klassenstufe."
        case .translate:
            return "Übersetze den Text auf dem Bild. Ist er auf Deutsch, übersetze ihn ins Englische, sonst ins Deutsche."
        case .latinSentence:
            return """
            Lateinischer Satz auf dem Bild (falls es mehrere sind: jeden Satz einzeln). Antworte kurz und nur mit diesen Punkten, ohne Einleitung:
            **Übersetzung:** eine gute deutsche Übersetzung.
            **Gliederung:** Hauptsatz (HS), Gliedsätze (GS, mit Art und Einleitewort, z. B. »cum-Satz, temporal/kausal«) und satzwertige Konstruktionen (sK) jeweils mit der lateinischen Passage.
            **Satzwertige Konstruktionen:** benenne genau, z. B. AcI, NcI, PC mit PPP/PPA/PFA (Bezugswort angeben), Ablativus absolutus, Gerundium/Gerundiv, und gib die wörtliche und die freie Übersetzung.
            **Wichtige Formen:** Prädikate (Person, Numerus, Tempus, Modus, Genus verbi) und auffällige Kasus-Funktionen (z. B. Ablativ des Mittels, Dativ des Besitzers).
            Nutze kurze Stichpunkte, keine langen Erklärungen.
            """
        case .latinWord:
            return """
            Lateinische Wörter auf dem Bild. Für jedes Wort eine kurze Bestimmung, ohne Einleitung:
            **Wort** – Grundform (Lexikonform, z. B. »laudare, laudo, laudavi, laudatum« oder »rex, regis m.«), Wortart, Bedeutung(en).
            Bestimmung der vorliegenden Form: bei Nomen/Adjektiv/Partizip Deklination (a-, o-, 3., u-, e-Dekl.), Kasus, Numerus, Genus; bei Verben Konjugation (a-, e-, i-, kons., gemischte), Person, Numerus, Tempus, Modus, Genus verbi.
            Wenn mehrere Bestimmungen möglich sind, liste alle kurz auf.
            """
        }
    }
}

enum PromptBuilder {
    static func system(grade: String, subject: String?) -> String {
        var text = """
        Du bist ein geduldiger, kompetenter Nachhilfelehrer in einer Notiz-App für die Schule.
        Der Schüler ist in: \(grade).
        """
        if let subject, !subject.isEmpty {
            text += "\nFach: \(subject)."
        }
        text += """

        Regeln:
        - Antworte auf Deutsch, außer die Aufgabe verlangt eine andere Sprache.
        - Formatiere mit Markdown: kurze Überschriften (##), Listen, **fett** für Ergebnisse.
        - Schreib mathematische Formeln in LaTeX: im Text mit $…$, abgesetzte Formeln mit $$…$$. Einfache Zahlen und Rechnungen ohne Formeln schreibst du normal.
        - Wenn ein Bild mitgeschickt wird, ist das ein vom Schüler eingekreister Ausschnitt einer Buch- oder Heftseite. Lies ihn genau.
        - Sei so kurz wie möglich und so ausführlich wie nötig.
        """
        return text
    }
}

/// Wandelt häufiges LaTeX in lesbaren Text um (für die Live-Anzeige und ohne Internet).
enum LatexLite {
    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "n": "ⁿ", "x": "ˣ", "(": "⁽", ")": "⁾",
    ]
    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "n": "ₙ", "x": "ₓ",
    ]

    /// Enthält der Text Formeln, die KaTeX schöner darstellen kann?
    static func containsMath(_ s: String) -> Bool {
        s.contains("$") || s.contains("\\(") || s.contains("\\[") || s.contains("\\frac") || s.contains("\\sqrt")
    }

    static func clean(_ input: String) -> String {
        var s = input
        // Brüche und Wurzeln zuerst (mehrfach, für verschachtelte Ausdrücke)
        for _ in 0..<3 {
            s = s.replacingOccurrences(of: #"\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}"#, with: "($1)/($2)", options: .regularExpression)
            s = s.replacingOccurrences(of: #"\\sqrt\{([^{}]*)\}"#, with: "√($1)", options: .regularExpression)
            s = s.replacingOccurrences(of: #"\\(?:text|mathrm|mathbf|operatorname)\{([^{}]*)\}"#, with: "$1", options: .regularExpression)
        }
        let replacements: [(String, String)] = [
            ("\\Leftrightarrow", "⇔"), ("\\Rightarrow", "⇒"), ("\\rightarrow", "→"),
            ("\\left", ""), ("\\right", ""),
            ("\\[", ""), ("\\]", ""), ("\\(", ""), ("\\)", ""), ("$$", ""),
            ("\\cdot", "·"), ("\\times", "×"), ("\\div", "÷"), ("\\pm", "±"), ("\\mp", "∓"),
            ("\\leq", "≤"), ("\\geq", "≥"), ("\\le", "≤"), ("\\ge", "≥"), ("\\neq", "≠"),
            ("\\approx", "≈"), ("\\pi", "π"), ("\\alpha", "α"), ("\\beta", "β"),
            ("\\gamma", "γ"), ("\\Delta", "Δ"), ("\\delta", "δ"), ("\\infty", "∞"),
            ("\\to", "→"), ("\\quad", "  "), ("\\degree", "°"),
            ("\\,", " "), ("\\;", " "), ("\\!", ""),
        ]
        for (a, b) in replacements { s = s.replacingOccurrences(of: a, with: b) }
        s = scripts(in: s, marker: "^", map: superscripts)
        s = scripts(in: s, marker: "_", map: subscripts)
        s = s.replacingOccurrences(of: #"\$([^$\n]+)\$"#, with: "$1", options: .regularExpression)
        return s
    }

    /// Ersetzt x^2, x^{12}, a_1 usw. durch hoch- bzw. tiefgestellte Zeichen, wo es möglich ist.
    private static func scripts(in s: String, marker: Character, map: [Character: Character]) -> String {
        var out = ""
        var chars = Array(s)[...]
        while let c = chars.popFirst() {
            guard c == marker, let next = chars.first else { out.append(c); continue }
            let group: [Character]
            let consumed: Int
            if next == "{", let close = chars.firstIndex(of: "}") {
                group = Array(chars[chars.index(after: chars.startIndex)..<close])
                consumed = group.count + 2
            } else {
                group = [next]
                consumed = 1
            }
            if !group.isEmpty, group.allSatisfy({ map[$0] != nil }) {
                out.append(contentsOf: group.compactMap { map[$0] })
                chars = chars.dropFirst(consumed)
            } else {
                out.append(c)
            }
        }
        return out
    }
}
