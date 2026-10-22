import SwiftUI
import PencilKit

/// Stifte in der eigenen Werkzeugleiste oben (ersetzt Apples Leiste unten).
enum InkTool: String, CaseIterable, Identifiable {
    case pen, pencil, marker, eraser, lasso

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: return "Stift"
        case .pencil: return "Bleistift"
        case .marker: return "Textmarker"
        case .eraser: return "Radierer"
        case .lasso: return "Auswählen"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .pencil: return "pencil"
        case .marker: return "highlighter"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        }
    }

    var usesColor: Bool { self == .pen || self == .pencil || self == .marker }
}

/// Merkt sich Stift, Farben und Strichstärke (auch über App-Neustarts).
@MainActor
final class InkSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    static let penColors: [UIColor] = [
        UIColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1),
        UIColor(red: 0.12, green: 0.36, blue: 1.00, alpha: 1),
        UIColor(red: 0.90, green: 0.20, blue: 0.18, alpha: 1),
        UIColor(red: 0.12, green: 0.62, blue: 0.31, alpha: 1),
        UIColor(red: 0.54, green: 0.25, blue: 0.99, alpha: 1),
        UIColor(red: 1.00, green: 0.54, blue: 0.00, alpha: 1),
    ]

    static let markerColors: [UIColor] = [
        UIColor(red: 1.00, green: 0.88, blue: 0.10, alpha: 1),
        UIColor(red: 0.45, green: 0.95, blue: 0.40, alpha: 1),
        UIColor(red: 1.00, green: 0.45, blue: 0.75, alpha: 1),
        UIColor(red: 0.35, green: 0.80, blue: 1.00, alpha: 1),
        UIColor(red: 1.00, green: 0.65, blue: 0.20, alpha: 1),
    ]

    static let widthTitles = ["Fein", "Mittel", "Dick"]

    @Published var tool: InkTool { didSet { defaults.set(tool.rawValue, forKey: "ink.tool") } }
    @Published var penColor: UIColor { didSet { defaults.set(penColor.hexString, forKey: "ink.penColor") } }
    @Published var markerColor: UIColor { didSet { defaults.set(markerColor.hexString, forKey: "ink.markerColor") } }
    @Published var widthIndex: Int { didSet { defaults.set(widthIndex, forKey: "ink.width") } }
    @Published var eraserWholeStrokes: Bool { didSet { defaults.set(eraserWholeStrokes, forKey: "ink.eraserWhole") } }

    private var toolBeforeEraser: InkTool = .pen

    init() {
        tool = InkTool(rawValue: defaults.string(forKey: "ink.tool") ?? "") ?? .pen
        penColor = UIColor(hex: defaults.string(forKey: "ink.penColor") ?? "") ?? Self.penColors[0]
        markerColor = UIColor(hex: defaults.string(forKey: "ink.markerColor") ?? "") ?? Self.markerColors[0]
        widthIndex = defaults.object(forKey: "ink.width") as? Int ?? 1
        eraserWholeStrokes = defaults.bool(forKey: "ink.eraserWhole")
    }

    /// Farbe des aktuellen Stifts (für die Anzeige in der Leiste).
    var currentColor: UIColor {
        tool == .marker ? markerColor : penColor
    }

    func setColor(_ color: UIColor) {
        if tool == .marker { markerColor = color } else { penColor = color }
        if !tool.usesColor { tool = .pen }
    }

    /// Strichstärke des Stifts (auch für die vorgeschriebene Handschrift).
    var penWidth: CGFloat { width(for: .pen) }

    private func width(for tool: InkTool) -> CGFloat {
        let i = min(max(widthIndex, 0), 2)
        switch tool {
        case .pen: return [2, 4, 8][i]
        case .pencil: return [2, 5, 10][i]
        case .marker: return [12, 20, 32][i]
        default: return 4
        }
    }

    var pkTool: PKTool {
        switch tool {
        case .pen: return PKInkingTool(.pen, color: penColor, width: width(for: .pen))
        case .pencil: return PKInkingTool(.pencil, color: penColor, width: width(for: .pencil))
        case .marker: return PKInkingTool(.marker, color: markerColor, width: width(for: .marker))
        case .eraser: return PKEraserTool(eraserWholeStrokes ? .vector : .bitmap)
        case .lasso: return PKLassoTool()
        }
    }

    /// Für Doppeltippen auf dem Pencil: zwischen Radierer und vorherigem Stift wechseln.
    func toggleEraser() {
        if tool == .eraser {
            tool = toolBeforeEraser
        } else {
            toolBeforeEraser = tool
            tool = .eraser
        }
    }
}

extension UIColor {
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    convenience init?(hex: String) {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }

    func isSameColor(_ other: UIColor) -> Bool { hexString == other.hexString }
}

// MARK: - Leiste oben

/// Stifte, Farbe und Strichstärke in einer Kapsel.
struct InkToolbar: View {
    @ObservedObject var ink: InkSettings
    var compact = false
    @State private var showOptions = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(compact ? [InkTool.pen, .marker, .eraser, .lasso] : InkTool.allCases) { tool in
                Button {
                    if ink.tool == tool, tool.usesColor || tool == .eraser {
                        showOptions = true
                    } else {
                        ink.tool = tool
                        Haptics.tap()
                    }
                } label: {
                    ToolbarIcon(symbol: tool.symbol, active: ink.tool == tool)
                }
                .help(tool.title)
            }
            Button { showOptions = true } label: {
                ZStack {
                    Circle()
                        .fill(Color(uiColor: ink.currentColor))
                        .frame(width: 24, height: 24)
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                        .frame(width: 24, height: 24)
                }
                .frame(width: 40, height: 40)
                .contentShape(Circle())
            }
            .help("Farbe und Strichstärke")
            .popover(isPresented: $showOptions, arrowEdge: .top) {
                InkOptionsView(ink: ink)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}

struct InkOptionsView: View {
    @ObservedObject var ink: InkSettings

    private var palette: [UIColor] {
        ink.tool == .marker ? InkSettings.markerColors : InkSettings.penColors
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if ink.tool == .eraser {
                Text("Radierer").font(.headline)
                Picker("Radierer", selection: $ink.eraserWholeStrokes) {
                    Text("Teilweise").tag(false)
                    Text("Ganze Striche").tag(true)
                }
                .pickerStyle(.segmented)
            } else {
                Text(ink.tool.usesColor ? ink.tool.title : "Stift").font(.headline)
                HStack(spacing: 12) {
                    ForEach(Array(palette.enumerated()), id: \.offset) { _, color in
                        Button { ink.setColor(color) } label: {
                            Circle()
                                .fill(Color(uiColor: color))
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if ink.currentColor.isSameColor(color) {
                                        Circle().strokeBorder(Color.primary, lineWidth: 2.5).padding(-4)
                                    }
                                }
                        }
                        .buttonStyle(PressableStyle())
                    }
                    ColorPicker("Eigene Farbe", selection: Binding(
                        get: { Color(uiColor: ink.currentColor) },
                        set: { ink.setColor(UIColor($0)) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                }
                Text("Strichstärke").font(.subheadline.weight(.semibold))
                Picker("Strichstärke", selection: $ink.widthIndex) {
                    ForEach(0..<3, id: \.self) { i in Text(InkSettings.widthTitles[i]).tag(i) }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(20)
        .frame(width: 330)
    }
}
