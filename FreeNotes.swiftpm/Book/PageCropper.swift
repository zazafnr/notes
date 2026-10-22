import UIKit

/// Schneidet aus einem Bildschirmfoto die Buchseite(n) aus.
enum PageCropper {
    enum Part { case left, right, spread }

    /// Bereich der Seite(n) in Bildpunkten; ohne Treffer das ganze Bild.
    static func pageBounds(in image: UIImage) -> CGRect {
        guard let cg = image.cgImage else { return CGRect(origin: .zero, size: image.size) }
        let full = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        // Verkleinert analysieren (schnell genug, genau genug)
        let w = 300
        let h = max(Int(Double(cg.height) / Double(cg.width) * Double(w)), 1)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return full }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var luminance = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Double(pixels[i * 4]), g = Double(pixels[i * 4 + 1]), b = Double(pixels[i * 4 + 2])
            luminance[i] = (0.299 * r + 0.587 * g + 0.114 * b) / 255
        }
        guard let found = PageDetection.pageRect(luminance: luminance, width: w, height: h) else { return full }
        let sx = CGFloat(cg.width) / CGFloat(w), sy = CGFloat(cg.height) / CGFloat(h)
        // CGContext-Zeilen beginnen hier oben (Bitmap-Speicher ist von oben nach unten)
        return CGRect(x: CGFloat(found.x.lowerBound) * sx, y: CGFloat(found.y.lowerBound) * sy,
                      width: CGFloat(found.x.count) * sx, height: CGFloat(found.y.count) * sy).integral
    }

    /// Linke, rechte Seite oder die ganze Doppelseite.
    static func crop(_ image: UIImage, part: Part) -> UIImage {
        guard let cg = image.cgImage else { return image }
        var rect = pageBounds(in: image)
        if part != .spread, PageDetection.isSpread(width: rect.width, height: rect.height) {
            let half = rect.width / 2
            rect = part == .left
                ? CGRect(x: rect.minX, y: rect.minY, width: half, height: rect.height)
                : CGRect(x: rect.minX + half, y: rect.minY, width: half, height: rect.height)
        }
        guard let cropped = cg.cropping(to: rect.integral) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }
}
