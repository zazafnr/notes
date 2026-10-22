import SwiftUI

/// Hintergrund hinter der Heftseite: weicher Verlauf in der Farbe des Hefts mit feiner Körnung,
/// wie eine Schreibtischunterlage – statt flachem Grau.
struct EditorBackdrop: View {
    var tint: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            LinearGradient(colors: baseColors, startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [tint.opacity(scheme == .dark ? 0.30 : 0.22), tint.opacity(0)],
                           center: UnitPoint(x: 0.12, y: 0.0), startRadius: 0, endRadius: 760)
            RadialGradient(colors: [tint.opacity(scheme == .dark ? 0.16 : 0.12), tint.opacity(0)],
                           center: UnitPoint(x: 0.95, y: 1.0), startRadius: 0, endRadius: 680)
            // Leichte Abdunklung zu den Rändern lenkt den Blick auf die Seite
            RadialGradient(colors: [.clear, .black.opacity(scheme == .dark ? 0.35 : 0.07)],
                           center: .center, startRadius: 380, endRadius: 1100)
            Image(uiImage: NoiseTexture.image)
                .resizable(resizingMode: .tile)
                .opacity(scheme == .dark ? 0.06 : 0.045)
                .blendMode(scheme == .dark ? .plusLighter : .multiply)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var baseColors: [Color] {
        scheme == .dark
            ? [Color(red: 0.115, green: 0.12, blue: 0.145), Color(red: 0.06, green: 0.065, blue: 0.08)]
            : [Color(red: 0.955, green: 0.955, blue: 0.97), Color(red: 0.875, green: 0.885, blue: 0.91)]
    }
}

/// Feines Rauschen als kachelbares Bild (einmal erzeugt).
enum NoiseTexture {
    static let image: UIImage = {
        let size = 160
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        var rng = SeededRandom(seed: 42)
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            let ctx = context.cgContext
            ctx.setFillColor(UIColor(white: 0.5, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            for y in 0..<size {
                for x in 0..<size {
                    let v = 0.5 + rng.signed() * 0.5
                    ctx.setFillColor(UIColor(white: CGFloat(v), alpha: 1).cgColor)
                    ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }()
}
