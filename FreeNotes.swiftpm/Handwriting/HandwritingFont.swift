import Foundation
import CoreGraphics

/// Ein geschriebener Buchstabe: Striche in x-Höhen-Einheiten.
/// Die Grundlinie liegt bei y = 0, y wächst nach unten (wie auf der Seite), x beginnt bei 0.
struct HWGlyph: Codable, Equatable {
    /// Breite (ohne Abstand zum nächsten Buchstaben).
    var w: Double
    /// Striche als flache Liste x0, y0, x1, y1, …
    var s: [[Double]]

    var strokes: [[CGPoint]] {
        s.map { flat in
            stride(from: 0, to: flat.count - 1, by: 2).map { CGPoint(x: flat[$0], y: flat[$0 + 1]) }
        }
    }

    init(w: Double, s: [[Double]]) {
        self.w = w
        self.s = s
    }

    /// Aus Strichen in x-Höhen-Einheiten (z. B. selbst geschrieben): links bündig, Breite berechnet.
    init?(strokes: [[CGPoint]]) {
        let all = strokes.flatMap { $0 }
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max() else { return nil }
        w = Double(maxX - minX)
        s = strokes.filter { !$0.isEmpty }.map { stroke in
            stroke.flatMap { [Self.round(Double($0.x - minX)), Self.round(Double($0.y))] }
        }
    }

    private static func round(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}

/// Eine Handschrift: mehrere Varianten pro Zeichen, damit gleiche Buchstaben nie identisch aussehen.
struct HandwritingFont: Codable, Equatable {
    /// Strichstärke im Verhältnis zur x-Höhe.
    var strokeWidth: Double
    var glyphs: [String: [HWGlyph]]

    /// Die mitgelieferte Schrift aus deiner Schriftprobe.
    static let builtIn: HandwritingFont = {
        guard let data = DefaultHandwriting.json.data(using: .utf8),
              let font = try? JSONDecoder().decode(HandwritingFont.self, from: data) else {
            return HandwritingFont(strokeWidth: 0.17, glyphs: [:])
        }
        return font
    }()

    /// Eigene Buchstaben ersetzen die mitgelieferten vollständig (alle Varianten).
    func merged(with custom: [String: [HWGlyph]]) -> HandwritingFont {
        var copy = self
        for (key, variants) in custom where !variants.isEmpty {
            copy.glyphs[key] = variants
        }
        return copy
    }

    /// Wie ein Zeichen geschrieben wird – mit Ersatz für Zeichen, die es nicht direkt gibt.
    func resolve(_ character: Character) -> HWResolved? {
        let key = String(character)
        if let variants = glyphs[key], !variants.isEmpty {
            return HWResolved(variants: variants, key: key)
        }
        if let sup = Self.superscripts[character],
           let variants = glyphs[String(sup.0)], !variants.isEmpty {
            return HWResolved(variants: variants, key: String(sup.0), scale: sup.1, raise: sup.2)
        }
        if let replacement = Self.replacements[character], let variants = glyphs[replacement], !variants.isEmpty {
            return HWResolved(variants: variants, key: replacement)
        }
        // é → e, Ç → C …
        let folded = key.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "de_DE"))
        if folded != key, let variants = glyphs[folded], !variants.isEmpty {
            return HWResolved(variants: variants, key: folded)
        }
        return nil
    }

    static let superscripts: [Character: (Character, Double, Double)] = [
        "²": ("2", 0.55, 1.15), "³": ("3", 0.55, 1.15), "¹": ("1", 0.55, 1.15), "⁴": ("4", 0.55, 1.15),
        "⁰": ("0", 0.55, 1.15), "⁵": ("5", 0.55, 1.15), "⁶": ("6", 0.55, 1.15), "⁷": ("7", 0.55, 1.15),
        "⁸": ("8", 0.55, 1.15), "⁹": ("9", 0.55, 1.15), "⁻": ("-", 0.6, 1.3), "ⁿ": ("n", 0.6, 1.25),
        "₀": ("0", 0.55, -0.35), "₁": ("1", 0.55, -0.35), "₂": ("2", 0.55, -0.35), "₃": ("3", 0.55, -0.35),
        "₄": ("4", 0.55, -0.35), "ₙ": ("n", 0.6, -0.3),
    ]

    static let replacements: [Character: String] = [
        "„": "\"", "“": "\"", "”": "\"", "«": "\"", "»": "\"", "‚": ",", "‘": "'", "’": "'", "´": "'", "`": "'",
        "–": "-", "—": "-", "−": "-", "‐": "-", "⋅": "·", "∙": "·", "•": "·", "∗": "*",
        "⟹": "⇒", "⇔": "⇒", "↔": "→", "⟶": "→", "∶": ":", "ẞ": "ß", "ı": "i",
    ]
}

/// Ein aufgelöstes Zeichen (evtl. verkleinert und hochgestellt, z. B. ²).
struct HWResolved {
    var variants: [HWGlyph]
    var key: String
    var scale: Double = 1
    /// Anheben in x-Höhen (positiv = nach oben).
    var raise: Double = 0
}

/// Reproduzierbarer Zufall: gleiche Eingabe ergibt die gleiche Schrift (wichtig für Tests und Vorschau).
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Gleichverteilt in 0..<1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// Gleichverteilt in -1...1.
    mutating func signed() -> Double { unit() * 2 - 1 }

    /// Ungefähr normalverteilt um 0 (Summe aus drei Werten), meist in -1...1.
    mutating func soft() -> Double { (signed() + signed() + signed()) / 3 }

    mutating func index(_ count: Int) -> Int { count <= 1 ? 0 : Int(next() % UInt64(count)) }
}
