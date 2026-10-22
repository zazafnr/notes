import Foundation
import CoreGraphics

/// Anweisungen an die KI, wenn eine Antwort in Handschrift ins Heft oder auf einen Zettel soll.
enum HandwritingPrompts {
    /// Macht aus einer KI-Antwort das, was ein Schüler tatsächlich ins Heft schreiben würde.
    static func notebookSystem(grade: String) -> String {
        """
        Du formst eine Lösung so um, wie ein Schüler (\(grade)) sie ordentlich mit der Hand ins Schulheft schreibt. \
        Der Text wird anschließend Buchstabe für Buchstabe in seiner Handschrift ins Heft geschrieben.

        Regeln:
        - Nur reiner Text. Kein Markdown (keine **, #, Aufzählungszeichen wie * oder •, keine Tabellen), kein LaTeX, keine Emojis.
        - So kurz wie im echten Heft: nur Ergebnis und nötiger Rechenweg bzw. Antwortsätze, keine Erklärungen an den Schüler, keine Einleitung.
        - Teilaufgaben untereinander mit »a)«, »b)« … am Zeilenanfang.
        - Mathe: pro Zeile ein Rechenschritt bzw. eine Umformung, mit Leerzeichen um = + − · :. Schreibe Brüche als 3/4, Potenzen als x² oder x³ \
        (sonst x^5), Wurzeln als √(…), Malpunkt ·, Pi als π, Grad als °, ungefähr als ≈. Einheiten nicht vergessen.
        - Das Endergebnis einer Rechnung doppelt unterstreichen: schreib es zwischen == und ==, z. B. ==x = 7==. \
        Bei Textaufgaben zusätzlich einen kurzen Antwortsatz (beginnend mit »A:«).
        - Überschriften oder wichtige Begriffe einfach unterstreichen: zwischen __ und __.
        - Höchstens etwa 15 Zeilen, jede Zeile höchstens etwa 45 Zeichen (lange Sätze auf mehrere Zeilen verteilen).
        - Sprache wie in der Aufgabe (Englisch-Aufgabe → englische Antwort, Latein-Übersetzung → Deutsch).
        """
    }

    /// Nachricht mit der ursprünglichen Antwort (und optional der Frage).
    static func notebookUser(answer: String, question: String?, header: HeaderInfo) -> String {
        var text = ""
        if let question, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "Aufgabe / Frage:\n\(question)\n\n"
        }
        text += "Lösung, die umgeformt werden soll:\n\(answer)\n\n"
        switch header {
        case .none:
            text += "Schreib keine Überschrift, nur die Lösung."
        case .pageAndNumber(let known):
            text += """
            Die Lösung kommt auf eine neue Heftseite. Beginne mit einer unterstrichenen Kopfzeile wie im Heft üblich, \
            z. B. »__S. 42 Nr. 3__« (Seite im Buch und Aufgabennummer, erkennbar aus Aufgabe oder Lösung). \
            Ist die Seite unbekannt, nur »__Nr. 3__«; ist beides unbekannt, ein kurzes Thema als Überschrift.
            """
            if let known, !known.isEmpty {
                text += " Bekannt: \(known)."
            }
            text += " Danach eine Leerzeile."
        }
        text += "\n\nAntworte nur mit dem Heft-Text."
        return text
    }

    enum HeaderInfo: Equatable {
        case none
        /// Mit Kopfzeile »S. … Nr. …«; optional bekannte Angaben (z. B. Buchseite).
        case pageAndNumber(String?)
    }

    /// Räumt die Antwort auf: Code-Blöcke, Markdown-Reste und überlange Leerzeilen entfernen.
    static func cleanNotebookText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "```text", with: "").replacingOccurrences(of: "```", with: "")
        text = text.replacingOccurrences(of: "**", with: "")
        var lines = text.components(separatedBy: "\n").map { line -> String in
            var l = line
            while l.hasSuffix(" ") { l.removeLast() }
            if l.hasPrefix("#") { l = String(l.drop { $0 == "#" || $0 == " " }) }
            if l.hasPrefix("* ") || l.hasPrefix("• ") { l = "- " + l.dropFirst(2) }
            l = l.replacingOccurrences(of: "\\cdot", with: "·").replacingOccurrences(of: "\\times", with: "·")
            l = l.replacingOccurrences(of: "$", with: "")
            return l
        }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        var result: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty, result.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                continue
            }
            result.append(line)
        }
        return result.joined(separator: "\n")
    }

    // MARK: Arbeitsblatt ausfüllen

    static let worksheetSystem = """
    Du hilfst einem Schüler, ein Arbeitsblatt auszufüllen. Du siehst das Blatt als Bild und bekommst die erkannten \
    gedruckten Textzeilen mit ihrer Position. Finde jede Stelle, an die der Schüler etwas schreiben muss \
    (Lücken, Schreiblinien, leere Tabellenfelder, Kästchen, Platz unter einer Frage), und löse sie.

    Antworte ausschließlich mit JSON in genau diesem Format, ohne weiteren Text:
    {"felder":[{"text":"Antwort","x":0,"y":0,"w":0,"h":0}]}

    - x, y, w, h: das freie Rechteck in Bildpixeln, in das die Antwort geschrieben wird (x/y = linke obere Ecke).
    - Bei einer Schreiblinie oder Lücke »_____« liegt die Unterkante des Rechtecks genau auf der Linie, Höhe etwa so hoch wie die gedruckte Schrift.
    - Bei mehreren Schreiblinien untereinander: ein Rechteck über alle Linien.
    - Das Rechteck darf keinen gedruckten Text überdecken.
    - text: so kurz, wie ein Schüler es hinschreibt (keine Erklärungen, kein Markdown, kein LaTeX; Brüche als 3/4, Potenzen als x²).
    - Bereits ausgefüllte Stellen auslassen.
    """

    static func worksheetUser(imageSize: CGSize, ocr: [OCRLine], solutions: String?) -> String {
        var text = "Bildgröße: \(Int(imageSize.width)) × \(Int(imageSize.height)) Pixel.\n\nErkannte Textzeilen (x, y, w, h in Pixeln):\n"
        for line in ocr.prefix(160) {
            let r = line.rect
            text += "[\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width)), \(Int(r.height))] \(line.text)\n"
        }
        if let solutions, !solutions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += """

            Trage NUR diese bereits erarbeiteten Lösungen ein, jeweils an der passenden Stelle (andere Aufgaben leer lassen). \
            Hat die Aufgabe keine Lücken oder Linien, nutze freien Platz direkt neben oder unter der Aufgabe \
            (Rand, Zwischenraum) und teile längere Lösungen auf mehrere Felder auf.
            Lösungen:
            \(solutions)

            """
        }
        text += "\nGib jetzt das JSON mit allen Feldern."
        return text
    }

    struct OCRLine: Equatable {
        var text: String
        var rect: CGRect
    }
}

/// Ein Feld auf dem Arbeitsblatt, in das eine Antwort geschrieben wird (in Seitenkoordinaten).
struct WorksheetField: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var rect: CGRect

    static func == (a: WorksheetField, b: WorksheetField) -> Bool {
        a.text == b.text && a.rect == b.rect
    }

    /// Liest die JSON-Antwort der KI. `imageScale`: Bildpixel pro Seitenpunkt.
    static func parse(_ raw: String, imageScale: CGFloat, pageSize: CGSize) -> [WorksheetField] {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let list = (object["felder"] ?? object["fields"] ?? object["answers"]) as? [[String: Any]] ?? []
        let page = CGRect(origin: .zero, size: pageSize)
        return list.compactMap { entry in
            guard let text = (entry["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            func number(_ key: String) -> CGFloat? {
                if let d = entry[key] as? Double { return CGFloat(d) }
                if let i = entry[key] as? Int { return CGFloat(i) }
                if let s = entry[key] as? String, let d = Double(s) { return CGFloat(d) }
                return nil
            }
            guard let x = number("x"), let y = number("y"), let w = number("w"), let h = number("h"),
                  w > 2, h > 2, imageScale > 0 else { return nil }
            let rect = CGRect(x: x / imageScale, y: y / imageScale, width: w / imageScale, height: h / imageScale)
                .intersection(page)
            guard !rect.isNull, rect.width > 4, rect.height > 4 else { return nil }
            return WorksheetField(text: text, rect: rect)
        }
    }
}
