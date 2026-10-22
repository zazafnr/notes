import SwiftUI
import PencilKit

/// Einstellungen der Handschrift: Vorschau, Größe, Ordentlichkeit, Tempo und eigene Buchstaben.
struct HandwritingSettingsView: View {
    @ObservedObject private var hw = HandwritingStore.shared
    @State private var seed: UInt64 = 3
    @State private var preview: UIImage?
    @State private var training: TrainingStart?
    @State private var confirmReset = false

    private let sample = "__Meine Handschrift__\nS. 42 Nr. 3a) x + 5 = 12 | -5\n==x = 7==\nDer flinke Fuchs jagt zwei braune Kühe."

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                    } else {
                        Color.white.frame(height: 200)
                    }
                    Button {
                        seed &+= 1
                    } label: {
                        Label("Neu schreiben (andere Varianten)", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .font(.subheadline)
                }
                .padding(.vertical, 6)
            }
            .task(id: "\(seed)|\(hw.size)|\(hw.messiness)|\(hw.custom.count)") {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                renderPreview()
            }

            Section {
                VStack(alignment: .leading) {
                    Text("Größe: \(Int(hw.size * 100)) %")
                    Slider(value: $hw.size, in: 0.8...1.25, step: 0.05)
                }
                VStack(alignment: .leading) {
                    Text("Schrift")
                    HStack {
                        Text("ordentlich").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $hw.messiness, in: 0...1)
                        Text("schnell").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("Tempo beim Schreiben", selection: $hw.speed) {
                    ForEach(HWSpeed.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Aussehen")
            } footer: {
                Text("KI-Antworten werden mit diesen Einstellungen Strich für Strich wie mit dem Apple Pencil ins Heft geschrieben. Die Schrift sitzt auf den Linien bzw. Kästchen.")
            }

            ForEach(HandwritingStore.trainingGroups) { group in
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: 8)], spacing: 8) {
                        ForEach(group.characters, id: \.self) { char in
                            Button {
                                training = TrainingStart(characters: group.characters, index: group.characters.firstIndex(of: char) ?? 0)
                            } label: {
                                GlyphCell(character: char, glyph: hw.font.glyphs[char]?.first, isCustom: hw.custom[char] != nil)
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text(group.title)
                } footer: {
                    if group.title == HandwritingStore.trainingGroups.first?.title {
                        Text("Tippe auf ein Zeichen und schreib es bis zu dreimal selbst – dann sieht es genau aus wie bei dir. Ein Haken heißt: eigene Version.")
                    }
                }
            }

            Section {
                Button("Eigene Buchstaben zurücksetzen", role: .destructive) { confirmReset = true }
                    .disabled(hw.custom.isEmpty)
            } footer: {
                Text("Danach wird wieder die Schrift aus deiner Schriftprobe verwendet.")
            }
        }
        .navigationTitle("Meine Handschrift")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $training) { start in
            GlyphTrainingSheet(characters: start.characters, index: start.index)
        }
        .confirmationDialog("Alle selbst geschriebenen Buchstaben löschen?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Zurücksetzen", role: .destructive) { hw.resetCustom() }
        }
    }

    private func renderPreview() {
        let size = CGSize(width: 1000, height: 330)
        let ruling = HWRuling(lineHeight: 38, firstBaseline: 72, left: 40, right: 960, bottom: 320, preferredXHeight: 12.5)
        let xh = ruling.xHeight(scale: hw.size)
        let layout = HandwritingLayout.layout(sample.replacingOccurrences(of: " | ", with: "   | "), font: hw.font,
                                              style: hw.style(xHeight: xh), ruling: ruling, seed: seed)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.6
        let strokes = HandwritingInk.pkStrokes(layout.strokes, color: InkSettings.penColors[0],
                                               size: HandwritingInk.pointSize(penWidth: 4, xHeight: xh), xHeight: xh)
        let ink = PageRenderer.ink(PKDrawing(strokes: strokes), rect: CGRect(origin: .zero, size: size), scale: 1.6)
        preview = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let ctx = context.cgContext
            ctx.setStrokeColor(UIColor(red: 0.55, green: 0.70, blue: 0.90, alpha: 0.55).cgColor)
            ctx.setLineWidth(1.2)
            var y = 72.0
            while y < Double(size.height) {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: size.width, y: y))
                y += 38
            }
            ctx.strokePath()
            ink.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

struct TrainingStart: Identifiable {
    let id = UUID()
    var characters: [String]
    var index: Int
}

/// Kleines Kästchen mit dem Zeichen, wie es geschrieben wird.
struct GlyphCell: View {
    let character: String
    let glyph: HWGlyph?
    let isCustom: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemFill))
            if let glyph {
                GlyphShape(glyph: glyph)
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .padding(6)
            } else {
                Text(character).font(.title3).foregroundStyle(.secondary)
            }
            if isCustom {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white, Theme.accent)
                    .offset(x: 4, y: -4)
            }
        }
        .frame(height: 58)
    }
}

/// Zeichnet einen Buchstaben passend in den verfügbaren Platz (Grundlinie bei 75 % der Höhe).
struct GlyphShape: Shape {
    let glyph: HWGlyph

    func path(in rect: CGRect) -> Path {
        // Bereich von Großbuchstabenhöhe (−2,4) bis Unterlänge (+1,0)
        let k = rect.height / 3.4
        let baseline = rect.minY + 2.4 * k
        let width = CGFloat(glyph.w) * k
        let x0 = rect.midX - width / 2
        var path = Path()
        for stroke in glyph.strokes where !stroke.isEmpty {
            path.move(to: CGPoint(x: x0 + stroke[0].x * k, y: baseline + stroke[0].y * k))
            for p in stroke.dropFirst() {
                path.addLine(to: CGPoint(x: x0 + p.x * k, y: baseline + p.y * k))
            }
            if stroke.count == 1 {
                path.addLine(to: CGPoint(x: x0 + stroke[0].x * k + 0.5, y: baseline + stroke[0].y * k))
            }
        }
        return path
    }
}

// MARK: - Buchstaben selbst schreiben

/// Drei Kästchen mit Hilfslinien: Das Zeichen bis zu dreimal schreiben, damit es Abwechslung gibt.
struct GlyphTrainingSheet: View {
    let characters: [String]
    @State var index: Int
    @ObservedObject private var hw = HandwritingStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var canvases: [PKCanvasView] = (0..<3).map { _ in PKCanvasView() }
    @State private var hasInk: [Bool] = [false, false, false]

    /// Hilfslinien im Kästchen (Punkte): x-Höhe 50, Grundlinie bei 170.
    static let boxSize = CGSize(width: 210, height: 250)
    static let baseline: CGFloat = 165
    static let xHeight: CGFloat = 48

    private var character: String { characters[index] }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(character)
                        .font(.system(size: 54, weight: .semibold, design: .rounded))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Schreib »\(character)« ein- bis dreimal")
                            .font(.headline)
                        Text("Auf die blaue Grundlinie. Kleine Buchstaben wie a, e, n reichen bis zur gestrichelten Linie.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 16) {
                    ForEach(0..<3, id: \.self) { i in
                        VStack(spacing: 6) {
                            TrainingCanvas(canvas: canvases[i]) { hasInk[i] = $0 }
                                .frame(width: Self.boxSize.width, height: Self.boxSize.height)
                                .background(TrainingGuides())
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                            Button("Löschen") {
                                canvases[i].drawing = PKDrawing()
                                hasInk[i] = false
                            }
                            .font(.caption.weight(.medium))
                            .disabled(!hasInk[i])
                        }
                    }
                }

                if let current = hw.font.glyphs[character]?.first {
                    HStack(spacing: 10) {
                        Text(hw.custom[character] != nil ? "Deine Version:" : "Bisher:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        GlyphShape(glyph: current)
                            .stroke(Color.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .frame(width: 60, height: 60)
                        if hw.custom[character] != nil {
                            Button("Original wiederherstellen") { hw.setCustom([], for: character) }
                                .font(.subheadline)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("Buchstaben schreiben (\(index + 1)/\(characters.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        go(-1)
                    } label: { Label("Zurück", systemImage: "chevron.left") }
                    .disabled(index == 0)
                    Spacer()
                    Button {
                        save()
                        if index < characters.count - 1 { go(1) } else { dismiss() }
                    } label: {
                        Text(index < characters.count - 1 ? "Speichern & weiter" : "Speichern").bold()
                    }
                    .disabled(!hasInk.contains(true))
                    Spacer()
                    Button {
                        go(1)
                    } label: { Label("Überspringen", systemImage: "chevron.right") }
                    .disabled(index >= characters.count - 1)
                }
            }
        }
    }

    private func go(_ delta: Int) {
        index = min(max(index + delta, 0), characters.count - 1)
        for c in canvases { c.drawing = PKDrawing() }
        hasInk = [false, false, false]
    }

    private func save() {
        var variants: [HWGlyph] = []
        for canvas in canvases {
            let strokes = canvas.drawing.strokes.map { stroke -> [CGPoint] in
                stroke.path.interpolatedPoints(by: .distance(2.5)).map { point in
                    let p = point.location.applying(stroke.transform)
                    return CGPoint(x: p.x / Self.xHeight, y: (p.y - Self.baseline) / Self.xHeight)
                }
            }.filter { !$0.isEmpty }
            if !strokes.isEmpty, let glyph = HWGlyph(strokes: strokes) {
                variants.append(glyph)
            }
        }
        guard !variants.isEmpty else { return }
        hw.setCustom(variants, for: character)
        Haptics.success()
    }
}

/// Grundlinie, x-Höhe, Großbuchstaben- und Unterlängen-Linie.
struct TrainingGuides: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let b = GlyphTrainingSheet.baseline, xh = GlyphTrainingSheet.xHeight
            func line(_ y: CGFloat, _ color: Color, dashed: Bool = false, width: CGFloat = 1) {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, dash: dashed ? [6, 5] : []))
            }
            line(b - 2.2 * xh, .gray.opacity(0.25))
            line(b - xh, .gray.opacity(0.45), dashed: true)
            line(b, Color(red: 0.25, green: 0.5, blue: 0.95).opacity(0.8), width: 1.6)
            line(b + 0.9 * xh, .gray.opacity(0.25))
        }
    }
}

/// Zeichenfläche für ein Trainings-Kästchen (Stift und Finger).
struct TrainingCanvas: UIViewRepresentable {
    let canvas: PKCanvasView
    var onChange: (Bool) -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        canvas.isScrollEnabled = false
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ view: PKCanvasView, context: Context) {
        context.coordinator.onChange = onChange
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onChange: (Bool) -> Void

        init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            onChange(!canvasView.drawing.strokes.isEmpty)
        }
    }
}
