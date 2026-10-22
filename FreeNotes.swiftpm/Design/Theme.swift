import SwiftUI
import UIKit

enum Theme {
    static let subjectColors: [Color] = [
        Color(red: 0.36, green: 0.40, blue: 0.95),   // Indigo
        Color(red: 0.93, green: 0.35, blue: 0.40),   // Rot
        Color(red: 0.18, green: 0.68, blue: 0.53),   // Grün
        Color(red: 0.98, green: 0.60, blue: 0.20),   // Orange
        Color(red: 0.58, green: 0.38, blue: 0.90),   // Lila
        Color(red: 0.13, green: 0.60, blue: 0.86),   // Blau
        Color(red: 0.90, green: 0.38, blue: 0.68),   // Pink
        Color(red: 0.42, green: 0.47, blue: 0.54),   // Schiefer
    ]

    static func color(_ index: Int) -> Color {
        let n = subjectColors.count
        return subjectColors[((index % n) + n) % n]
    }

    static let accent = Color(red: 0.36, green: 0.40, blue: 0.95)

    static let aiColors: [Color] = [
        Color(red: 0.33, green: 0.38, blue: 0.98),
        Color(red: 0.62, green: 0.35, blue: 0.95),
        Color(red: 0.93, green: 0.36, blue: 0.70),
        Color(red: 0.99, green: 0.58, blue: 0.35),
    ]

    static let aiUIColors: [UIColor] = aiColors.map { UIColor($0) }

    static var aiGradient: LinearGradient {
        LinearGradient(colors: aiColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let subjectSymbols = [
        "function", "text.book.closed", "globe.europe.africa", "leaf", "atom",
        "flask", "clock", "paintpalette", "music.note", "figure.run",
        "laptopcomputer", "building.columns", "map", "brain.head.profile", "sum", "folder",
    ]
}

// MARK: - Glas-Optik

struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        // Liquid Glass gibt es erst ab iOS 26 (Xcode 26 / neues Swift Playgrounds).
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            material(content)
        }
        #else
        material(content)
        #endif
    }

    private func material(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.10), radius: 14, y: 6)
    }
}

extension View {
    func glass(cornerRadius: CGFloat = 18) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius))
    }
}

// MARK: - Buttons

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct ToolbarIcon: View {
    let symbol: String
    var active = false
    var gradient = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 40, height: 40)
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background {
                if active {
                    Circle().fill(gradient ? AnyShapeStyle(Theme.aiGradient) : AnyShapeStyle(Theme.accent))
                        .shadow(color: Theme.aiColors[1].opacity(gradient ? 0.5 : 0), radius: 8)
                }
            }
            .contentShape(Circle())
    }
}

// MARK: - Haptik

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func soft() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

// MARK: - Bild-Helfer

extension UIImage {
    func downscaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let factor = maxSide / longest
        let newSize = CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Um 90° gedreht (für gedrehte Scan-Seiten).
    func rotatedQuarter(clockwise: Bool) -> UIImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let newSize = CGSize(width: size.height, height: size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: newSize, format: format).image { context in
            let ctx = context.cgContext
            ctx.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            ctx.rotate(by: clockwise ? .pi / 2 : -.pi / 2)
            draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        }
    }

    func jpegBase64(maxSide: CGFloat = 1600) -> String? {
        downscaled(maxSide: maxSide).jpegData(compressionQuality: 0.85)?.base64EncodedString()
    }
}
