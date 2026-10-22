import Foundation

enum QuickAction: String, CaseIterable, Identifiable {
    case solve, explain, steps, hint, summarize, write, translate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solve: return "Lösen"
        case .explain: return "Erklären"
        case .steps: return "Schritt für Schritt"
        case .hint: return "Nur Tipp"
        case .summarize: return "Zusammenfassen"
        case .write: return "Text schreiben"
        case .translate: return "Übersetzen"
        }
    }

    var symbol: String {
        switch self {
        case .solve: return "checkmark.seal"
        case .explain: return "lightbulb"
        case .steps: return "list.number"
        case .hint: return "questionmark.bubble"
        case .summarize: return "text.redaction"
        case .write: return "pencil.line"
        case .translate: return "character.bubble"
        }
    }

    var prompt: String {
        switch self {
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
        - Schreib Formeln OHNE LaTeX, nur mit normalen Zeichen und Unicode, z. B. x², √2, ½, 3 · 4, ≤, π, Brüche als (a)/(b).
        - Wenn ein Bild mitgeschickt wird, ist das ein vom Schüler eingekreister Ausschnitt einer Buch- oder Heftseite. Lies ihn genau.
        - Sei so kurz wie möglich und so ausführlich wie nötig.
        """
        return text
    }
}

/// Wandelt häufiges LaTeX in lesbaren Text um, falls das Modell es trotzdem benutzt.
enum LatexLite {
    static func clean(_ input: String) -> String {
        var s = input
        let replacements: [(String, String)] = [
            ("\\[", ""), ("\\]", ""), ("\\(", ""), ("\\)", ""), ("$$", ""),
            ("\\cdot", "·"), ("\\times", "×"), ("\\div", "÷"), ("\\pm", "±"),
            ("\\leq", "≤"), ("\\geq", "≥"), ("\\le ", "≤ "), ("\\ge ", "≥ "), ("\\neq", "≠"),
            ("\\approx", "≈"), ("\\pi", "π"), ("\\alpha", "α"), ("\\beta", "β"),
            ("\\gamma", "γ"), ("\\Delta", "Δ"), ("\\infty", "∞"), ("\\rightarrow", "→"),
            ("\\Rightarrow", "⇒"), ("\\quad", "  "), ("\\,", " "), ("\\left", ""), ("\\right", ""),
            ("^2", "²"), ("^3", "³"),
        ]
        for (a, b) in replacements { s = s.replacingOccurrences(of: a, with: b) }
        s = s.replacingOccurrences(of: #"\\frac\{([^{}]*)\}\{([^{}]*)\}"#, with: "($1)/($2)", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\sqrt\{([^{}]*)\}"#, with: "√($1)", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\text\{([^{}]*)\}"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\$([^$\n]+)\$"#, with: "$1", options: .regularExpression)
        return s
    }
}
