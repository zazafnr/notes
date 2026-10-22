import SwiftUI
import Vision

/// Arbeitsblatt ausfüllen: Die KI findet die Lücken und Schreiblinien, die Antworten werden
/// danach in deiner Handschrift genau dort eingetragen.
struct WorksheetFillSheet: View {
    @ObservedObject var model: EditorModel
    /// Bereits vorhandene Lösungen (z. B. aus dem Chat), sonst löst die KI selbst.
    var solutions: String?
    /// Die Seite ist eine gerade eingefügte Buchseite.
    var fromBook = false
    /// Wo die eingekreiste Aufgabe liegt (Anteile 0…1): Nur dort wird eingetragen.
    var taskArea: CGRect? = nil
    /// Keine passenden Stellen gefunden: Lösung stattdessen als Heft-Eintrag schreiben.
    var onFallback: ((String) -> Void)? = nil
    @EnvironmentObject private var settings: AISettings
    @Environment(\.dismiss) private var dismiss

    @State private var pageImage: UIImage?
    @State private var fields: [WorksheetField] = []
    @State private var working = true
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    /// Bildpixel pro Seitenpunkt (lange Seite bleibt unter 1568 px, dann rechnet die KI in Original-Pixeln).
    private var imageScale: CGFloat {
        guard let page = model.currentPage else { return 1 }
        return min(1.4, 1560 / CGFloat(max(page.width, page.height)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    pagePreview
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                    }
                    if !working, fields.isEmpty, let solutions, let onFallback {
                        Button {
                            dismiss()
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 450_000_000)
                                onFallback(solutions)
                            }
                        } label: {
                            Label("Lösung stattdessen auf eine neue Heftseite schreiben", systemImage: "pencil.and.scribble")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if !fields.isEmpty { fieldList }
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(fromBook ? "Buchseite ausfüllen" : "Zettel ausfüllen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        task?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let list = fields.filter { !$0.text.trimmed.isEmpty }
                        dismiss()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 450_000_000)
                            model.writeFields(list)
                        }
                    } label: {
                        Label("Eintragen", systemImage: "pencil.and.scribble").font(.headline)
                    }
                    .disabled(working || fields.isEmpty)
                }
            }
        }
        .onAppear(perform: start)
        .onDisappear { task?.cancel() }
    }

    private var pagePreview: some View {
        ZStack {
            if let pageImage, let page = model.currentPage {
                Image(uiImage: pageImage)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        GeometryReader { geo in
                            let s = geo.size.width / CGFloat(page.width)
                            if let area = taskArea {
                                // Eingekreiste Aufgabe
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Theme.aiColors[1], style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                                    .frame(width: area.width * geo.size.width, height: area.height * geo.size.height)
                                    .offset(x: area.minX * geo.size.width, y: area.minY * geo.size.height)
                            }
                            ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                                let r = field.rect
                                ZStack(alignment: .topLeading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Theme.accent.opacity(0.12))
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(Theme.accent, lineWidth: 1.5)
                                    Text("\(index + 1)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(3)
                                        .background(Theme.accent, in: Circle())
                                        .offset(x: -8, y: -8)
                                }
                                .frame(width: r.width * s, height: r.height * s)
                                .offset(x: r.minX * s, y: r.minY * s)
                            }
                        }
                    }
            } else {
                Color.white.frame(height: 400)
            }
            if working {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(solutions == nil ? "KI löst das Blatt und sucht die Lücken …" : "KI sucht die passenden Stellen …")
                        .font(.subheadline.weight(.medium))
                }
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private var fieldList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Antworten (antippen zum Ändern)").font(.headline)
            ForEach($fields) { $field in
                let number = (fields.firstIndex { $0.id == field.id } ?? 0) + 1
                HStack(alignment: .top, spacing: 10) {
                    Text("\(number)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Theme.accent, in: Circle())
                    TextField("Antwort", text: $field.text, axis: .vertical)
                        .lineLimit(1...4)
                    Button(role: .destructive) {
                        fields.removeAll { $0.id == field.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: Ablauf

    private func start() {
        guard task == nil, let page = model.currentPage else { return }
        let scale = imageScale
        let image = model.currentPageImage(scale: scale)
        pageImage = image
        guard let image, let cg = image.cgImage else {
            working = false
            error = "Seite konnte nicht gelesen werden."
            return
        }
        let pixelSize = CGSize(width: CGFloat(page.width) * scale, height: CGFloat(page.height) * scale)
        let solutions = solutions
        let pageSize = page.size
        let taskRect = taskArea.map {
            CGRect(x: $0.minX * pixelSize.width, y: $0.minY * pixelSize.height,
                   width: $0.width * pixelSize.width, height: $0.height * pixelSize.height)
        }
        task = Task {
            let ocr = await Task.detached(priority: .userInitiated) { WorksheetOCR.lines(in: cg, size: pixelSize) }.value
            guard !Task.isCancelled else { return }
            do {
                let user = HandwritingPrompts.worksheetUser(imageSize: pixelSize, ocr: ocr, solutions: solutions, taskRect: taskRect)
                guard let base64 = image.jpegBase64(maxSide: 1600) else { throw AIError.empty }
                let raw = try await AIRequest.text(system: HandwritingPrompts.worksheetSystem, user: user,
                                                   images: [base64], settings: settings, effort: "medium")
                guard !Task.isCancelled else { return }
                let parsed = WorksheetField.parse(raw, imageScale: scale, pageSize: pageSize)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { fields = parsed }
                if parsed.isEmpty {
                    error = solutions == nil ? "Keine Lücken gefunden. Ist die Seite ein Arbeitsblatt?"
                        : "Auf der Seite ist kein Platz für die Lösung gefunden worden."
                }
            } catch is CancellationError {
                return
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            working = false
        }
    }
}

/// Gedruckte Textzeilen mit Position (in Bildpixeln, Ursprung oben links).
enum WorksheetOCR {
    static func lines(in image: CGImage, size: CGSize) -> [HandwritingPrompts.OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { obs -> HandwritingPrompts.OCRLine? in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            let b = obs.boundingBox
            let rect = CGRect(x: b.minX * size.width, y: (1 - b.maxY) * size.height,
                              width: b.width * size.width, height: b.height * size.height)
            return HandwritingPrompts.OCRLine(text: text, rect: rect)
        }
        return lines.sorted { abs($0.rect.minY - $1.rect.minY) < 6 ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
    }
}
