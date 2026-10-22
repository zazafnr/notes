import Foundation
import CoreGraphics

/// Wie geschrieben wird: Größe und wie »schnell hingeschrieben« es aussieht.
struct HWStyle: Equatable {
    /// Höhe der kleinen Buchstaben (a, e, n …) in Seitenpunkten.
    var xHeight: Double
    /// 0 = sehr ordentlich, 1 = schnell hingeschrieben.
    var messiness: Double = 0.5
    /// Abstände in x-Höhen.
    var letterSpacing: Double = 0.24
    var wordSpacing: Double = 0.95
    /// Schräglage (positiv = nach rechts geneigt).
    var slant: Double = 0
}

/// Wo auf der Seite geschrieben werden darf: Zeilen, Rand, letzte Zeile.
struct HWRuling: Equatable {
    var lineHeight: Double
    var firstBaseline: Double
    var left: Double
    var right: Double
    /// Tiefste erlaubte Grundlinie.
    var bottom: Double
    /// Passende x-Höhe für diese Lineatur (bei Größe 100 %).
    var preferredXHeight: Double

    /// Lineatur passend zum Papier: Auf liniertem und kariertem Papier sitzt die Schrift auf den Linien.
    static func forPaper(_ paper: PaperStyle, size: CGSize) -> HWRuling {
        let width = Double(size.width)
        let height = Double(size.height)
        switch paper {
        case .lined:
            // Linien wie im PageRenderer: ab y = 130 alle 38 Punkte, Rand bei x = 90
            var last = 130.0
            while last + 38 < height - 40 { last += 38 }
            return HWRuling(lineHeight: 38, firstBaseline: 168, left: 98, right: width - 45, bottom: last, preferredXHeight: 12.5)
        case .grid:
            // Kästchen 25 Punkte (5 mm): Text in jede zweite Kästchenreihe, zwei Kästchen Rand
            let step = 25.0
            let bottom = (floor((height - 30) / step) * step)
            return HWRuling(lineHeight: step * 2, firstBaseline: step * 3, left: step * 2, right: width - step * 2,
                            bottom: bottom, preferredXHeight: 12)
        case .dotted:
            let step = 30.0
            let bottom = floor((height - 30) / step) * step
            return HWRuling(lineHeight: step, firstBaseline: step * 3, left: step * 2, right: width - step * 2,
                            bottom: bottom, preferredXHeight: 9.5)
        case .blank:
            return HWRuling(lineHeight: 38, firstBaseline: 100, left: 60, right: width - 60,
                            bottom: height - 50, preferredXHeight: 12.5)
        }
    }

    /// Größe der Schrift für diese Lineatur; `scale` aus den Einstellungen (0,8 … 1,25).
    func xHeight(scale: Double) -> Double {
        // Großbuchstaben (≈2,2) und Unterlängen (≈0,9) sollen in eine Zeile passen
        let maxFit = lineHeight * 1.08 / 3.1
        return min(preferredXHeight * scale, max(maxFit, preferredXHeight))
    }

    /// Erste Grundlinie unter bereits Geschriebenem, mit `gapLines` freien Zeilen dazwischen.
    func baseline(below contentBottom: Double?, gapLines: Int = 1) -> Double {
        guard let contentBottom, contentBottom > firstBaseline - lineHeight else { return firstBaseline }
        let needed = contentBottom + lineHeight * (Double(gapLines) + 0.55)
        let steps = max(0, ceil((needed - firstBaseline) / lineHeight))
        return firstBaseline + steps * lineHeight
    }
}

/// Ein Strich, wie ihn der Stift zieht (Seitenkoordinaten, in Schreibreihenfolge).
struct HWStroke: Equatable {
    var points: [CGPoint]
    /// Strichstärke im Verhältnis zur normalen.
    var weight: Double = 1
    /// Letzter Strich eines Wortes (hier wird beim Vorschreiben zwischengespeichert).
    var endsWord = false
}

struct HWLayout: Equatable {
    var strokes: [HWStroke] = []
    /// Grundlinie der letzten geschriebenen Zeile.
    var lastBaseline: Double = 0
    /// Text, der nicht mehr auf die Seite gepasst hat (geht auf der nächsten Seite weiter).
    var overflow: String?
    /// Zeichen ohne passenden Buchstaben (werden ausgelassen).
    var missing: Set<Character> = []

    var bounds: CGRect {
        let all = strokes.flatMap(\.points)
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
              let minY = all.map(\.y).min(), let maxY = all.map(\.y).max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Setzt Text in Handschrift: Buchstabenvarianten, natürliche Schwankungen, Zeilenumbruch auf den Heftlinien.
///
/// Auszeichnungen im Text: `__so__` wird unterstrichen, `==so==` doppelt unterstrichen (Ergebnis).
enum HandwritingLayout {
    /// Ein Zeichen mit Unterstreichung (0 = keine, 1 = einfach, 2 = doppelt).
    typealias MarkedChar = (char: Character, underline: Int)

    static let capHeight = 2.2

    // MARK: Text auf Linien

    static func layout(_ text: String, font: HandwritingFont, style: HWStyle, ruling: HWRuling,
                       startBaseline: Double? = nil, seed: UInt64 = 1) -> HWLayout {
        var writer = Writer(font: font, style: style, seed: seed)
        var result = HWLayout()
        var baseline = startBaseline ?? ruling.firstBaseline
        let lines = parse(text)
        var firstLine = true

        lineLoop: for (lineIndex, line) in lines.enumerated() {
            if !firstLine { baseline += ruling.lineHeight }
            firstLine = false
            let words = split(line)
            if words.isEmpty {
                continue   // Leerzeile
            }
            if baseline > ruling.bottom + 0.5 {
                result.overflow = serialize(Array(lines[lineIndex...]))
                break lineLoop
            }
            let indent = Double(line.prefix { $0.char == " " }.count) * 0.45 * style.xHeight
            var x = ruling.left + indent
            writer.beginLine()
            for (wordIndex, word) in words.enumerated() {
                let placed = writer.prepare(word.chars)
                let atLineStart = x <= ruling.left + indent + 0.1
                let gap = atLineStart ? 0 : writer.wordGap()
                if !atLineStart, x + gap + placed.width > ruling.right {
                    // Umbruch vor diesem Wort
                    writer.finishUnderline(into: &result, baseline: baseline)
                    baseline += ruling.lineHeight
                    if baseline > ruling.bottom + 0.5 {
                        var rest: [MarkedChar] = []
                        for (i, w) in words[wordIndex...].enumerated() {
                            if i > 0 { rest.append((" ", w.chars.first?.underline ?? 0)) }
                            rest += w.chars
                        }
                        result.overflow = serialize([rest] + Array(lines[(lineIndex + 1)...]))
                        break lineLoop
                    }
                    x = ruling.left
                    writer.beginLine()
                } else {
                    x += gap
                }
                writer.emit(placed, x: &x, baseline: &baseline, ruling: ruling, into: &result)
            }
            writer.finishUnderline(into: &result, baseline: baseline)
            result.lastBaseline = baseline
        }
        result.missing = writer.missing
        return result
    }

    // MARK: Text in ein Kästchen (Arbeitsblatt)

    /// Schreibt Text in ein Feld; die Schrift wird kleiner, bis alles hineinpasst.
    /// Bei einem einzeiligen Feld sitzt die Schrift auf der Unterkante (der Schreiblinie).
    static func fit(_ text: String, in rect: CGRect, font: HandwritingFont, style: HWStyle, seed: UInt64 = 1) -> HWLayout {
        let minX = Double(rect.minX), maxX = Double(rect.maxX)
        let minY = Double(rect.minY), maxY = Double(rect.maxY), h = Double(rect.height)
        var xh = min(style.xHeight, max(h * 0.5, 5))
        var best = HWLayout()
        for _ in 0..<12 {
            let lineHeight = xh * 3.2
            let singleLine = h < lineHeight * 1.7
            let firstBaseline = singleLine ? maxY - 0.2 * xh : minY + capHeight * xh * 1.05
            let ruling = HWRuling(lineHeight: lineHeight, firstBaseline: firstBaseline,
                                  left: minX + 0.15 * xh, right: maxX - 0.1 * xh,
                                  bottom: singleLine ? firstBaseline : maxY - 0.15 * xh,
                                  preferredXHeight: xh)
            var s = style
            s.xHeight = xh
            best = layout(text, font: font, style: s, ruling: ruling, seed: seed)
            // Auch ein zu langes Einzelwort, das intern umbricht, gilt als »passt nicht«
            if best.overflow == nil, best.lastBaseline <= ruling.bottom + 0.5 { return best }
            xh *= 0.88
            if xh < 4 { break }
        }
        // Passt nicht: in kleinster Größe ohne Begrenzung nach unten schreiben
        var s = style
        s.xHeight = max(xh, 4)
        let ruling = HWRuling(lineHeight: s.xHeight * 3.2, firstBaseline: minY + capHeight * s.xHeight,
                              left: minX, right: maxX, bottom: .greatestFiniteMagnitude, preferredXHeight: s.xHeight)
        return layout(text, font: font, style: s, ruling: ruling, seed: seed)
    }

    // MARK: Auszeichnungen

    /// Zerlegt Text in Zeilen aus Zeichen mit Unterstreichungs-Angabe.
    static func parse(_ text: String) -> [[MarkedChar]] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
        return normalized.components(separatedBy: "\n").map { line in
            var result: [MarkedChar] = []
            var underline = 0
            let chars = Array(line)
            var i = 0
            while i < chars.count {
                if i + 1 < chars.count, chars[i] == "=", chars[i + 1] == "=", underline != 1,
                   underline == 2 || chars[(i + 2)...].contains("=") {
                    underline = underline == 2 ? 0 : 2
                    i += 2
                    continue
                }
                if i + 1 < chars.count, chars[i] == "_", chars[i + 1] == "_", underline != 2 {
                    underline = underline == 1 ? 0 : 1
                    i += 2
                    continue
                }
                result.append((chars[i], underline))
                i += 1
            }
            return result
        }
    }

    struct Word {
        var chars: [MarkedChar]
    }

    static func split(_ line: [MarkedChar]) -> [Word] {
        var words: [Word] = []
        var current: [MarkedChar] = []
        for item in line {
            if item.char == " " {
                if !current.isEmpty { words.append(Word(chars: current)); current = [] }
            } else {
                current.append(item)
            }
        }
        if !current.isEmpty { words.append(Word(chars: current)) }
        return words
    }

    static func serializeLine(_ line: [MarkedChar]) -> String {
        var out = ""
        var state = 0
        for item in line {
            if item.underline != state {
                if state == 1 { out += "__" } else if state == 2 { out += "==" }
                if item.underline == 1 { out += "__" } else if item.underline == 2 { out += "==" }
                state = item.underline
            }
            out.append(item.char)
        }
        if state == 1 { out += "__" } else if state == 2 { out += "==" }
        return out
    }

    static func serialize(_ lines: [[MarkedChar]]) -> String {
        lines.map(serializeLine).joined(separator: "\n")
    }

    // MARK: Schreiber

    /// Ein vorbereiteter Buchstabe mit gewählter Variante und eigener kleiner Schwankung.
    struct PlacedGlyph {
        var glyph: HWGlyph?
        var underline: Int
        var advance: Double
        var scale: Double
        var rotation: Double
        var shear: Double
        var yOffset: Double
        var glyphScale: Double
    }

    struct PlacedWord {
        var glyphs: [PlacedGlyph]
        var width: Double { glyphs.reduce(0) { $0 + $1.advance } }
    }

    struct Writer {
        let font: HandwritingFont
        let style: HWStyle
        var rng: SeededRandom
        var lastVariant: [String: Int] = [:]
        var missing: Set<Character> = []
        /// Neigung der aktuellen Zeile (Zeilen laufen nie ganz gerade).
        var lineTilt = 0.0
        var lineDrift = 0.0
        var lineStartX: Double?
        var underlineStart: (x: Double, kind: Int)?
        var underlineEnd = 0.0

        init(font: HandwritingFont, style: HWStyle, seed: UInt64) {
            self.font = font
            self.style = style
            rng = SeededRandom(seed: seed)
        }

        var m: Double { min(max(style.messiness, 0), 1) }

        mutating func beginLine() {
            lineTilt = rng.soft() * 0.006 * (0.3 + m)
            lineDrift = rng.soft() * 0.08 * style.xHeight * m
            lineStartX = nil
        }

        mutating func wordGap() -> Double {
            (style.wordSpacing + rng.soft() * 0.25 * m) * style.xHeight
        }

        mutating func prepare(_ chars: [MarkedChar]) -> PlacedWord {
            let xh = style.xHeight
            var glyphs: [PlacedGlyph] = []
            for (index, item) in chars.enumerated() {
                guard let resolved = font.resolve(item.char) else {
                    missing.insert(item.char)
                    glyphs.append(PlacedGlyph(glyph: nil, underline: item.underline, advance: 0.6 * xh, scale: 1,
                                              rotation: 0, shear: 0, yOffset: 0, glyphScale: 1))
                    continue
                }
                // Variante wählen, nicht zweimal hintereinander dieselbe
                var variant = rng.index(resolved.variants.count)
                if resolved.variants.count > 1, lastVariant[resolved.key] == variant {
                    variant = (variant + 1 + rng.index(resolved.variants.count - 1)) % resolved.variants.count
                }
                lastVariant[resolved.key] = variant
                let glyph = resolved.variants[variant]
                let sizeJitter = 1 + rng.soft() * 0.06 * m
                let k = xh * sizeJitter
                var spacing = style.letterSpacing * (1 + rng.soft() * 0.35 * m)
                let next = index + 1 < chars.count ? chars[index + 1].char : nil
                if let next, ".,:;".contains(next) { spacing *= 0.5 }
                if ".,".contains(item.char) { spacing *= 0.6 }
                let advance = (glyph.w * resolved.scale + spacing) * k
                glyphs.append(PlacedGlyph(glyph: glyph, underline: item.underline, advance: advance,
                                          scale: k, rotation: rng.soft() * 0.04 * m,
                                          shear: style.slant + rng.soft() * 0.05 * m,
                                          yOffset: -resolved.raise * xh + rng.soft() * 0.05 * xh * m,
                                          glyphScale: resolved.scale))
            }
            return PlacedWord(glyphs: glyphs)
        }

        /// Schreibt ein Wort; bricht innerhalb um, wenn ein einzelnes Wort zu lang für die Zeile ist.
        mutating func emit(_ word: PlacedWord, x: inout Double, baseline: inout Double, ruling: HWRuling,
                           into result: inout HWLayout) {
            var currentBaseline = baseline
            let left = ruling.left, right = ruling.right, lineHeight = ruling.lineHeight
            let firstStroke = result.strokes.count
            for placed in word.glyphs {
                if x + placed.advance > right + 0.5 * style.xHeight, x > left + style.xHeight {
                    finishUnderline(into: &result, baseline: currentBaseline)
                    currentBaseline += lineHeight
                    x = left
                    beginLine()
                }
                if lineStartX == nil { lineStartX = x }
                let drift = lineDrift + (x - (lineStartX ?? x)) * lineTilt
                let base = currentBaseline + drift
                if placed.underline > 0 {
                    if underlineStart == nil || underlineStart?.kind != placed.underline {
                        finishUnderline(into: &result, baseline: currentBaseline)
                        underlineStart = (x, placed.underline)
                    }
                } else if underlineStart != nil {
                    finishUnderline(into: &result, baseline: currentBaseline)
                }
                if let glyph = placed.glyph {
                    let k = placed.scale * placed.glyphScale
                    let cosR = cos(placed.rotation), sinR = sin(placed.rotation)
                    for stroke in glyph.strokes where !stroke.isEmpty {
                        let points = stroke.map { p -> CGPoint in
                            let lx = Double(p.x) * k
                            let ly = Double(p.y) * k
                            let sx = lx - placed.shear * ly
                            let rx = sx * cosR - ly * sinR
                            let ry = sx * sinR + ly * cosR
                            return CGPoint(x: x + rx, y: base + placed.yOffset + ry)
                        }
                        result.strokes.append(HWStroke(points: points))
                    }
                    underlineEnd = x + glyph.w * k
                }
                x += placed.advance
            }
            if result.strokes.count > firstStroke {
                result.strokes[result.strokes.count - 1].endsWord = true
            }
            baseline = currentBaseline
        }

        /// Unterstreichung bis zum Ende des letzten Buchstabens (einfach oder doppelt).
        mutating func finishUnderline(into result: inout HWLayout, baseline: Double) {
            guard let start = underlineStart else { return }
            underlineStart = nil
            let xh = style.xHeight
            let x0 = start.x - 0.1 * xh
            let x1 = max(underlineEnd + 0.15 * xh, x0 + xh)
            for line in 0..<start.kind {
                let y = baseline + (0.45 + Double(line) * 0.3) * xh
                let a = rng.soft() * 0.06 * xh
                let b = rng.soft() * 0.06 * xh
                let bow = (0.03 + rng.unit() * 0.04) * xh
                let n = 6
                let points = (0...n).map { i -> CGPoint in
                    let t = Double(i) / Double(n)
                    let yy = y + a * (1 - t) + b * t + bow * sin(t * .pi)
                    return CGPoint(x: x0 + (x1 - x0) * t, y: yy)
                }
                result.strokes.append(HWStroke(points: points, weight: 0.9, endsWord: line == start.kind - 1))
            }
        }
    }
}
