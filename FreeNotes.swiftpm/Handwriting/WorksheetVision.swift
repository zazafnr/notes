import Foundation
import CoreGraphics

/// Bildausschnitt eines Arbeitsblatts: Umrechnung zwischen Seitenpunkten und Bildpixeln.
struct WorksheetCrop: Equatable {
    /// Bereich auf der Seite (Seitenpunkte).
    var region: CGRect
    /// Bildpixel pro Seitenpunkt.
    var scale: CGFloat

    init(region: CGRect, scale: CGFloat) {
        self.region = region
        self.scale = scale
    }

    /// Ausschnitt um die eingekreiste Aufgabe (mit etwas Rand) oder die ganze Seite.
    /// Die lange Seite bleibt unter 1560 px, damit die KI in genau diesen Pixeln rechnet.
    init(area: CGRect?, pageSize: CGSize) {
        let page = CGRect(origin: .zero, size: pageSize)
        var region = page
        if let a = area, a.width > 0, a.height > 0 {
            let r = CGRect(x: a.minX * pageSize.width, y: a.minY * pageSize.height,
                           width: a.width * pageSize.width, height: a.height * pageSize.height)
            let margin = max(24, 0.05 * pageSize.width)
            region = r.insetBy(dx: -margin, dy: -margin).intersection(page)
            if region.isNull || region.width < 20 || region.height < 20 { region = page }
        }
        self.region = region.integral.intersection(page)
        scale = min(4, 1560 / max(self.region.width, self.region.height, 1))
    }

    var pixelSize: CGSize {
        CGSize(width: (region.width * scale).rounded(), height: (region.height * scale).rounded())
    }

    func toPage(_ r: CGRect) -> CGRect {
        CGRect(x: region.minX + r.minX / scale, y: region.minY + r.minY / scale,
               width: r.width / scale, height: r.height / scale)
    }

    func toPixels(_ r: CGRect) -> CGRect {
        CGRect(x: (r.minX - region.minX) * scale, y: (r.minY - region.minY) * scale,
               width: r.width * scale, height: r.height * scale)
    }
}

/// Pixel-Auswertung eines Arbeitsblatts: Tinte erkennen und Felder auf Linien einrasten.
enum WorksheetVision {
    /// Graustufenbild, zeilenweise von oben, 0 = schwarz … 255 = weiß.
    struct Gray {
        let width: Int
        let height: Int
        var pixels: [UInt8]

        init(width: Int, height: Int, pixels: [UInt8]) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        /// Weißes Bild (für Tests).
        init(width: Int, height: Int) {
            self.init(width: width, height: height, pixels: [UInt8](repeating: 255, count: width * height))
        }

        mutating func fill(_ rect: CGRect, value: UInt8 = 0) {
            let x0 = max(0, Int(rect.minX)), x1 = min(width, Int(rect.maxX))
            let y0 = max(0, Int(rect.minY)), y1 = min(height, Int(rect.maxY))
            guard x0 < x1, y0 < y1 else { return }
            for y in y0..<y1 { for x in x0..<x1 { pixels[y * width + x] = value } }
        }
    }

    static func gray(from image: CGImage) -> Gray? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? Gray(width: w, height: h, pixels: pixels) : nil
    }

    /// Schwelle für »dunkel« im Umfeld eines Feldes: deutlich dunkler als der Durchschnitt dort
    /// (gleicht graue Fotos und Schatten aus). Nur ein kleiner Bereich wird angeschaut – das ist schnell.
    static func threshold(_ g: Gray, around rect: CGRect) -> Int {
        let x0 = max(0, Int(rect.minX)), x1 = min(g.width - 1, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY)), y1 = min(g.height - 1, Int(rect.maxY))
        guard x1 > x0, y1 > y0 else { return 140 }
        var sum = 0, count = 0
        var y = y0
        while y <= y1 {
            var x = x0
            let row = y * g.width
            while x <= x1 {
                sum += Int(g.pixels[row + x])
                count += 1
                x += 3
            }
            y += 3
        }
        let mean = count > 0 ? sum / count : 230
        return min(190, max(70, mean - 45))
    }

    @inline(__always)
    static func dark(_ g: Gray, _ x: Int, _ y: Int, _ threshold: Int) -> Bool {
        Int(g.pixels[y * g.width + x]) < threshold
    }

    /// Liegt bei Zeile `y` eine dünne waagrechte Linie über den Spalten x0…x1?
    /// Dünn heißt: knapp darüber und darunter ist frei (unterscheidet Linien von Textzeilen).
    /// Leicht schiefe Linien werden über ein kleines Fenster erkannt.
    static func isLine(_ g: Gray, threshold t: Int, y: Int, x0: Int, x1: Int, unit: Double) -> Bool {
        let h = g.height
        let window = max(2, Int(unit.rounded()))
        let offset = max(4, Int((2.5 * unit).rounded()))
        guard y - window >= 0, y + window < h, x0 >= 0, x1 < g.width, x1 > x0 else { return false }
        var hits = 0
        for x in x0...x1 {
            var isDark = false
            for yy in (y - window)...(y + window) where dark(g, x, yy, t) { isDark = true; break }
            guard isDark else { continue }
            let above = y - offset >= 0 && dark(g, x, y - offset, t)
            let below = y + offset < h && dark(g, x, y + offset, t)
            if !above && !below { hits += 1 }
        }
        return Double(hits) >= 0.5 * Double(x1 - x0 + 1)
    }

    /// Schiebt ein ungefähr angegebenes Feld (Pixel) auf die nächste Schreiblinie bzw. in die Tabellenzelle:
    /// Unterkante knapp über der Linie darunter, Oberkante unter einer Linie darüber (falls vorhanden).
    /// Ohne Linie in der Nähe bleibt das Feld, wie es ist.
    static func snap(_ rect: CGRect, gray g: Gray, unit: Double) -> CGRect {
        let w = g.width, h = g.height
        guard g.pixels.count == w * h, rect.width > 4, rect.height > 4 else { return rect }
        let x0 = max(0, Int(rect.minX + 0.1 * rect.width))
        let x1 = min(w - 1, Int(rect.maxX - 0.1 * rect.width))
        guard x1 > x0 else { return rect }
        let height = Double(rect.height)
        let reach = max(0.8 * height, 12)
        let from = max(1, Int(Double(rect.maxY) - reach)), to = min(h - 2, Int(Double(rect.maxY) + reach))
        guard from < to else { return rect }
        let t = threshold(g, around: CGRect(x: Double(x0), y: Double(rect.minY) - reach, width: Double(x1 - x0),
                                            height: height + 2 * reach))
        func line(_ y: Int) -> Bool { isLine(g, threshold: t, y: y, x0: x0, x1: x1, unit: unit) }
        var best: Int?
        for y in from...to where line(y) {
            if best == nil || abs(Double(y) - Double(rect.maxY)) < abs(Double(best!) - Double(rect.maxY)) { best = y }
        }
        guard var found = best else { return rect }
        // Oberkante der Linie
        while found - 1 > 0, line(found - 1) { found -= 1 }
        let gap = max(3, 1.5 * unit)
        let bottom = Double(found) - gap
        var top = bottom - height
        // Linie darüber (Tabellenzelle oder Zeile darüber) begrenzt das Feld nach oben
        var y = Int(bottom - 4)
        let limit = max(1, Int(bottom - 1.5 * height))
        while y > limit {
            if line(y) {
                top = Double(y) + max(4, 2 * unit)
                break
            }
            y -= 1
        }
        guard bottom - top >= 8 else { return rect }
        return CGRect(x: Double(rect.minX), y: top, width: Double(rect.width), height: bottom - top)
    }
}
