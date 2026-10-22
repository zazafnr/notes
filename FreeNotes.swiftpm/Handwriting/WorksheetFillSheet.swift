import SwiftUI

/// Arbeitsblatt ausfüllen: Die KI liest den (eingekreisten) Ausschnitt scharf, gibt die Stellen an,
/// die App rastet sie auf Linien und Tabellenzellen ein, dann wird in deiner Handschrift eingetragen.
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

    enum Stage: Equatable {
        case reading, thinking, answering, done
    }

    @State private var crop: WorksheetCrop?
    @State private var cropImage: UIImage?
    @State private var fields: [WorksheetField] = []
    @State private var stage: Stage = .reading
    @State private var startedAt = Date()
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var watchdog: Task<Void, Never>?
    @State private var timedOut = false
    @State private var attempt = 0
    /// Welcher KI-Anbieter gerade gefragt wird (oder warum gewechselt wurde).
    @State private var providerStatus = ""

    /// Länger wartet niemand: danach abbrechen und »Nochmal« anbieten.
    private let timeout: UInt64 = 80

    private var working: Bool { stage != .done }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    preview
                    if let error { errorBox(error) }
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
                        cancelRunning()
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
        .onAppear { start() }
        .onDisappear { cancelRunning() }
    }

    // MARK: Teile

    private var preview: some View {
        ZStack {
            if let cropImage, let crop {
                Image(uiImage: cropImage)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        GeometryReader { geo in
                            let s = geo.size.width / max(crop.pixelSize.width, 1)
                            if let area = taskArea, let page = model.currentPage {
                                // Eingekreiste Aufgabe
                                let r = crop.toPixels(CGRect(x: area.minX * page.width, y: area.minY * page.height,
                                                             width: area.width * page.width, height: area.height * page.height))
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Theme.aiColors[1], style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                                    .frame(width: r.width * s, height: r.height * s)
                                    .offset(x: r.minX * s, y: r.minY * s)
                            }
                            ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                                let r = crop.toPixels(field.rect)
                                ZStack(alignment: .topLeading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Theme.accent.opacity(0.12))
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(Theme.accent, lineWidth: 1.5)
                                    Text("\(index + 1)")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(4)
                                        .background(Theme.accent, in: Circle())
                                        .offset(x: -9, y: -9)
                                    Text(field.text)
                                        .font(.system(size: max(9, min(16, r.height * s * 0.45))))
                                        .foregroundStyle(Theme.accent)
                                        .lineLimit(2)
                                        .padding(.leading, 6)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                                        .padding(.bottom, 2)
                                }
                                .frame(width: r.width * s, height: r.height * s)
                                .offset(x: r.minX * s, y: r.minY * s)
                            }
                        }
                    }
            } else {
                Color.white.frame(height: 300)
            }
            if working { progressBox }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private var progressBox: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(stageText).font(.subheadline.weight(.medium))
            if !providerStatus.isEmpty {
                Text(providerStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("\(Int(context.date.timeIntervalSince(startedAt))) s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var stageText: String {
        switch stage {
        case .reading: return "Lese den Zettel …"
        case .thinking: return solutions == nil ? "KI löst die Aufgabe …" : "KI sucht die passenden Stellen …"
        case .answering: return "KI trägt die Antworten zusammen …"
        case .done: return ""
        }
    }

    private func errorBox(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline)
            HStack {
                Button {
                    start(retry: true)
                } label: {
                    Label("Nochmal versuchen", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                if let solutions, let onFallback {
                    Button {
                        dismiss()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 450_000_000)
                            onFallback(solutions)
                        }
                    } label: {
                        Label("Auf neue Heftseite schreiben", systemImage: "pencil.and.scribble")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    private func cancelRunning() {
        watchdog?.cancel()
        task?.cancel()
    }

    private func start(retry: Bool = false) {
        guard let page = model.currentPage else { return }
        if !retry, task != nil { return }
        cancelRunning()
        attempt += 1
        error = nil
        providerStatus = ""
        timedOut = false
        fields = []
        stage = .reading
        startedAt = Date()

        let crop = WorksheetCrop(area: taskArea, pageSize: page.size)
        guard let rendered = model.renderRegion(crop.region, scale: crop.scale), let cg = rendered.cgImage else {
            stage = .done
            error = "Die Seite konnte nicht gelesen werden."
            return
        }
        self.crop = crop
        cropImage = UIImage(cgImage: cg)
        let pixelSize = CGSize(width: cg.width, height: cg.height)
        let pageSize = page.size
        let taskRect = taskArea.map {
            crop.toPixels(CGRect(x: $0.minX * pageSize.width, y: $0.minY * pageSize.height,
                                 width: $0.width * pageSize.width, height: $0.height * pageSize.height))
        }
        let solutions = solutions
        // Gleicher Modus wie im Chat mit Bild (dort funktioniert es zuverlässig); beim Wiederholen schneller
        let effort = retry ? "low" : "medium"
        let unit = Double(crop.scale)

        // Raster und Graustufen gehen in Millisekunden – direkt hier, ohne Hintergrund-Umweg.
        // (Die Texterkennung von Apple ist weggefallen: Sie blieb in Swift Playgrounds manchmal hängen,
        // und die KI liest den scharfen Ausschnitt ohnehin selbst.)
        let gridImage = WorksheetGrid.image(from: cg)
        let gray = WorksheetVision.gray(from: cg)
        guard let base64 = gridImage.jpegBase64(maxSide: 1600) else {
            stage = .done
            error = "Die Seite konnte nicht gelesen werden."
            return
        }
        stage = .thinking

        let running = Task { @MainActor in
            do {
                let user = HandwritingPrompts.worksheetUser(imageSize: pixelSize, ocr: [], solutions: solutions, taskRect: taskRect)
                let raw = try await AIRequest.text(system: HandwritingPrompts.worksheetSystem, user: user, images: [base64],
                                                   settings: settings, effort: effort,
                                                   onText: { _ in if stage == .thinking { stage = .answering } },
                                                   onStatus: { providerStatus = $0 })
                guard !Task.isCancelled else { return }
                let page = CGRect(origin: .zero, size: pageSize)
                let parsed: [WorksheetField] = WorksheetField.pixelFields(raw).compactMap { item in
                    let snapped = gray.map { WorksheetVision.snap(item.rect, gray: $0, unit: unit) } ?? item.rect
                    let rect = crop.toPage(snapped).intersection(page)
                    guard !rect.isNull, rect.width > 4, rect.height > 4 else { return nil }
                    return WorksheetField(text: item.text, rect: rect)
                }
                watchdog?.cancel()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { fields = parsed }
                if parsed.isEmpty {
                    error = "Die KI hat keine passende Stelle angegeben. Versuch es nochmal oder kreise die Aufgabe etwas größer ein."
                }
            } catch {
                watchdog?.cancel()
                if timedOut || error is CancellationError || Task.isCancelled {
                    return   // Zeitlimit meldet der Wächter selbst
                } else {
                    self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            stage = .done
        }
        task = running
        watchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            guard !Task.isCancelled else { return }
            timedOut = true
            running.cancel()
            // Sofort Bescheid geben, auch wenn ein Schritt noch hängt
            error = "Das hat zu lange gedauert (über \(timeout) s). Versuch es nochmal – dann geht es schneller."
                + (providerStatus.isEmpty ? "" : "\nZuletzt: \(providerStatus)")
            stage = .done
        }
    }
}

/// Helles Koordinaten-Raster über dem Ausschnitt: Die KI liest daran Pixel-Positionen genauer ab.
enum WorksheetGrid {
    static func image(from cg: CGImage, step: Int = 100) -> UIImage {
        let size = CGSize(width: cg.width, height: cg.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
            let ctx = context.cgContext
            ctx.setStrokeColor(UIColor(red: 0.2, green: 0.6, blue: 1, alpha: 0.28).cgColor)
            ctx.setLineWidth(1)
            for x in stride(from: step, to: cg.width, by: step) {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: cg.height))
            }
            for y in stride(from: step, to: cg.height, by: step) {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: cg.width, y: y))
            }
            ctx.strokePath()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: UIColor(red: 0.1, green: 0.45, blue: 0.95, alpha: 0.9),
                .backgroundColor: UIColor.white.withAlphaComponent(0.8),
            ]
            for x in stride(from: step, to: cg.width, by: step) {
                ("\(x)" as NSString).draw(at: CGPoint(x: x + 2, y: 2), withAttributes: attributes)
            }
            for y in stride(from: step, to: cg.height, by: step) {
                ("\(y)" as NSString).draw(at: CGPoint(x: 2, y: y + 2), withAttributes: attributes)
            }
        }
    }
}
