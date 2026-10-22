import Foundation

/// Findet die Buchseite(n) in einem Bildschirmfoto des Buch-Fensters:
/// Buchseiten sind hell, der Hintergrund des digi4school-Lesers ist dunkel.
enum PageDetection {
    /// Längster zusammenhängender Bereich mit Werten über `threshold`, der `center` enthält.
    /// Kleine Lücken (z. B. der Schatten in der Buchmitte) bis `maxGap` werden überbrückt.
    static func run(in values: [Double], threshold: Double, center: Int, maxGap: Int) -> Range<Int>? {
        guard !values.isEmpty else { return nil }
        let bright = values.map { $0 >= threshold }
        // Lücken schließen
        var filled = bright
        var i = 0
        while i < bright.count {
            if !bright[i] {
                var j = i
                while j < bright.count && !bright[j] { j += 1 }
                if i > 0, j < bright.count, j - i <= maxGap {
                    for k in i..<j { filled[k] = true }
                }
                i = j
            } else {
                i += 1
            }
        }
        // Bereich um die Mitte, sonst der längste helle Bereich
        var runs: [Range<Int>] = []
        var start: Int?
        for (index, on) in filled.enumerated() {
            if on, start == nil { start = index }
            if !on, let s = start { runs.append(s..<index); start = nil }
        }
        if let s = start { runs.append(s..<filled.count) }
        let c = min(max(center, 0), values.count - 1)
        return runs.first(where: { $0.contains(c) }) ?? runs.max(by: { $0.count < $1.count })
    }

    /// Rechteck der Seite(n) in einem Helligkeitsraster (Werte 0…1, zeilenweise).
    static func pageRect(luminance: [Double], width: Int, height: Int) -> (x: Range<Int>, y: Range<Int>)? {
        guard width > 0, height > 0, luminance.count == width * height else { return nil }
        let bright = 0.8
        // Spalten: Anteil heller Pixel im mittleren Streifen (ohne Kopf- und Fußleiste der Seite)
        let rowLo = height / 4, rowHi = height * 3 / 4
        var columns = [Double](repeating: 0, count: width)
        for x in 0..<width {
            var count = 0
            for y in rowLo..<rowHi where luminance[y * width + x] >= bright { count += 1 }
            columns[x] = Double(count) / Double(max(rowHi - rowLo, 1))
        }
        guard let xs = run(in: columns, threshold: 0.5, center: width / 2, maxGap: max(width / 40, 2)),
              xs.count > width / 8 else { return nil }
        // Zeilen: hell innerhalb der Seitenspalten, aber nicht auch daneben.
        // So fallen helle Kopf- und Fußleisten des Lesers weg, die über die ganze Breite gehen.
        let outside = (0..<width).filter { !xs.contains($0) }
        let useOutside = outside.count >= width / 20
        var rows = [Double](repeating: 0, count: height)
        for y in 0..<height {
            var inside = 0
            for x in xs where luminance[y * width + x] >= bright { inside += 1 }
            var score = Double(inside) / Double(xs.count)
            if useOutside {
                var out = 0
                for x in outside where luminance[y * width + x] >= bright { out += 1 }
                score -= Double(out) / Double(outside.count)
            }
            rows[y] = score
        }
        guard let ys = run(in: rows, threshold: 0.4, center: height / 2, maxGap: max(height / 80, 2)),
              ys.count > height / 8 else { return nil }
        return (xs, ys)
    }

    /// Doppelseite, wenn deutlich breiter als hoch.
    static func isSpread(width: Double, height: Double) -> Bool {
        width > height * 1.05
    }
}
