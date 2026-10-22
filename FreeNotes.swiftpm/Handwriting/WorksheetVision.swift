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

    /// Tinte: deutlich dunkler als die Umgebung (gleicht Schatten und graue Fotos aus).
    static func inkMask(_ image: Gray) -> [Bool] {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return [] }
        var integral = [Int](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var rowSum = 0
            for x in 0..<w {
                rowSum += Int(image.pixels[y * w + x])
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + rowSum
            }
        }
        let r = max(8, min(w, h) / 30)
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - r), y1 = min(h - 1, y + r)
            for x in 0..<w {
                let p = Int(image.pixels[y * w + x])
                guard p < 215 else { continue }
                let x0 = max(0, x - r), x1 = min(w - 1, x + r)
                let count = (x1 - x0 + 1) * (y1 - y0 + 1)
                let sum = integral[(y1 + 1) * (w + 1) + x1 + 1] - integral[y0 * (w + 1) + x1 + 1]
                    - integral[(y1 + 1) * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
                mask[y * w + x] = p < sum / count - 20
            }
        }
        return mask
    }

    /// Liegt bei Zeile `y` eine dünne waagrechte Linie über den Spalten x0…x1?
    /// Dünn heißt: knapp darüber und darunter ist frei (unterscheidet Linien von Textzeilen).
    /// Leicht schiefe Linien werden über ein kleines Fenster erkannt.
    static func isLine(_ ink: [Bool], width w: Int, height h: Int, y: Int, x0: Int, x1: Int, unit: Double) -> Bool {
        let window = max(2, Int(unit.rounded()))
        let offset = max(4, Int((2.5 * unit).rounded()))
        guard y - window >= 0, y + window < h, x1 > x0 else { return false }
        var hits = 0
        for x in x0...x1 {
            var dark = false
            for yy in (y - window)...(y + window) where ink[yy * w + x] { dark = true; break }
            guard dark else { continue }
            let above = y - offset >= 0 && ink[(y - offset) * w + x]
            let below = y + offset < h && ink[(y + offset) * w + x]
            if !above && !below { hits += 1 }
        }
        return Double(hits) >= 0.5 * Double(x1 - x0 + 1)
    }

    /// Schiebt ein ungefähr angegebenes Feld (Pixel) auf die nächste Schreiblinie bzw. in die Tabellenzelle:
    /// Unterkante knapp über der Linie darunter, Oberkante unter einer Linie darüber (falls vorhanden).
    /// Ohne Linie in der Nähe bleibt das Feld, wie es ist.
    static func snap(_ rect: CGRect, ink: [Bool], width w: Int, height h: Int, unit: Double) -> CGRect {
        guard ink.count == w * h, rect.width > 4, rect.height > 4 else { return rect }
        let x0 = max(0, Int(rect.minX + 0.1 * rect.width))
        let x1 = min(w - 1, Int(rect.maxX - 0.1 * rect.width))
        guard x1 > x0 else { return rect }
        let height = Double(rect.height)
        let reach = max(0.8 * height, 12)
        let from = max(1, Int(Double(rect.maxY) - reach)), to = min(h - 2, Int(Double(rect.maxY) + reach))
        guard from < to else { return rect }
        var best: Int?
        for y in from...to where isLine(ink, width: w, height: h, y: y, x0: x0, x1: x1, unit: unit) {
            if best == nil || abs(Double(y) - Double(rect.maxY)) < abs(Double(best!) - Double(rect.maxY)) { best = y }
        }
        guard var line = best else { return rect }
        // Oberkante der Linie
        while line - 1 > 0, isLine(ink, width: w, height: h, y: line - 1, x0: x0, x1: x1, unit: unit) { line -= 1 }
        let gap = max(3, 1.5 * unit)
        let bottom = Double(line) - gap
        var top = bottom - height
        // Linie darüber (Tabellenzelle oder Zeile darüber) begrenzt das Feld nach oben
        var y = Int(bottom - 4)
        let limit = max(1, Int(bottom - 1.5 * height))
        while y > limit {
            if isLine(ink, width: w, height: h, y: y, x0: x0, x1: x1, unit: unit) {
                top = Double(y) + max(4, 2 * unit)
                break
            }
            y -= 1
        }
        guard bottom - top >= 8 else { return rect }
        return CGRect(x: Double(rect.minX), y: top, width: Double(rect.width), height: bottom - top)
    }
}
