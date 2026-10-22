import SwiftUI
import PencilKit
import PDFKit
import Vision

struct LassoSnapshot: Identifiable {
    let id = UUID()
    let image: UIImage
    let rect: CGRect
    /// Ganze Buchseite, wenn im Buch eingekreist wurde (zum Ausfüllen im Heft).
    var sourcePage: UIImage? = nil
    /// Wo die eingekreiste Aufgabe auf der Buchseite liegt (Anteile 0…1).
    var sourceArea: CGRect? = nil
}

@MainActor
final class EditorModel: ObservableObject {
    let notebookID: UUID
    let store: LibraryStore
    let ink = InkSettings()

    @Published var pageIndex = 0
    @Published var aiMode = false
    @Published var showPanel = false
    @Published var imageEditMode = false
    @Published var geometryTool: GeometryTool?
    @Published var rulerActive = false
    @Published var wholePage = false
    @Published var showBook = false
    /// Buch über den ganzen Bildschirm (Heft bleibt im Hintergrund offen).
    @Published var bookFullScreen = false
    @Published var snapshot: LassoSnapshot?

    weak var host: PageCanvasHost? {
        didSet {
            // Neue Seite angezeigt: ggf. dort weiterschreiben
            if host !== oldValue, !writingQueue.isEmpty {
                Task { @MainActor [weak self] in self?.continueWriting() }
            }
        }
    }

    /// Handschrift, die gerade vorgeschrieben wird.
    @Published var writing: WritingStatus?
    var animator: HandwritingAnimator?
    var writingQueue: [WritingPart] = []
    var skipWritingAnimation = false
    var navigatingForWriting = false

    private var lastLassoRect: CGRect?
    private var pending: (page: UUID, drawing: PKDrawing)?
    private var saveTask: Task<Void, Never>?
    private var isClosed = false

    init(notebookID: UUID, store: LibraryStore) {
        self.notebookID = notebookID
        self.store = store
        if let nb = store.notebook(notebookID) {
            pageIndex = min(nb.lastPage ?? 0, max(nb.pages.count - 1, 0))
        }
        store.updateNotebook(notebookID) { $0.opened = Date() }
    }

    var notebook: Notebook? { store.notebook(notebookID) }

    var currentPage: Page? {
        guard let nb = notebook, nb.pages.indices.contains(pageIndex) else { return nil }
        return nb.pages[pageIndex]
    }

    // MARK: Speichern

    func drawingChanged(_ drawing: PKDrawing, page: UUID) {
        pending = (page, drawing)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        guard let p = pending else { return }
        pending = nil
        store.saveDrawing(p.drawing, notebook: notebookID, page: p.page)
        store.updateNotebook(notebookID) { _ in }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        skipWriting()
        flush()
        store.updateNotebook(notebookID) { $0.lastPage = pageIndex }
        updateThumbnail()
        store.saveNow()
        indexText()
    }

    /// Liest Handschrift und Scans per Texterkennung, damit man Hefte nach Inhalt durchsuchen kann.
    func indexText() {
        guard let nb = notebook else { return }
        var images: [CGImage] = []
        for page in nb.pages.prefix(40) {
            let drawing = store.loadDrawing(notebook: notebookID, page: page.id)
            guard !drawing.strokes.isEmpty || page.background != nil || !page.items.isEmpty else { continue }
            let image = PageRenderer.render(page: page, drawing: drawing,
                                            image: { [store, notebookID] in store.image($0, notebook: notebookID) },
                                            scale: 1.2)
            if let cg = image.cgImage { images.append(cg) }
        }
        let id = notebookID
        let store = store
        Task.detached(priority: .utility) {
            let text = TextRecognizer.recognize(images)
            await MainActor.run {
                store.updateNotebook(id) { $0.searchText = text }
            }
        }
    }

    func updateThumbnail() {
        guard let nb = notebook, let first = nb.pages.first else { return }
        let drawing = store.loadDrawing(notebook: notebookID, page: first.id)
        let image = PageRenderer.render(page: first, drawing: drawing,
                                        image: { [store, notebookID] in store.image($0, notebook: notebookID) },
                                        scale: 360 / CGFloat(first.width))
        store.saveThumbnail(image, notebook: notebookID)
    }

    // MARK: Seiten

    func goTo(_ index: Int) {
        guard let nb = notebook, nb.pages.indices.contains(index), index != pageIndex else { return }
        // Selbst geblättert, während geschrieben wird: den Rest sofort fertig schreiben
        if writing != nil, !navigatingForWriting { skipWriting() }
        flush()
        aiMode = false
        imageEditMode = false
        geometryTool = nil
        withAnimation(.easeInOut(duration: 0.25)) { pageIndex = index }
        Haptics.tap()
    }

    /// Blättern per Wischen.
    func flip(_ delta: Int) {
        guard let nb = notebook else { return }
        let target = pageIndex + delta
        if nb.pages.indices.contains(target) {
            goTo(target)
        } else {
            Haptics.soft()
        }
    }

    func duplicatePage(at index: Int) {
        flush()
        guard let nb = notebook, nb.pages.indices.contains(index) else { return }
        var copy = nb.pages[index]
        copy.id = UUID()
        copy.modified = Date()
        let drawing = store.loadDrawing(notebook: notebookID, page: nb.pages[index].id)
        store.saveDrawing(drawing, notebook: notebookID, page: copy.id)
        store.updateNotebook(notebookID) { $0.pages.insert(copy, at: index + 1) }
        Haptics.success()
    }

    /// Dreht eine Seite um 90° – Tinte, Bilder und Scan drehen sich mit (z. B. für Querformat).
    func rotatePage(at index: Int, clockwise: Bool) {
        skipWriting()
        flush()
        guard let nb = notebook, nb.pages.indices.contains(index) else { return }
        let page = nb.pages[index]
        var rotated = page.rotated(clockwise: clockwise)
        // Neue Seiten-ID, damit die Zeichenfläche frisch geladen wird (Rückgängig-Verlauf passt sonst nicht mehr)
        rotated.id = UUID()
        let t = Page.rotationTransform(size: page.size, clockwise: clockwise)
        let drawing = store.loadDrawing(notebook: notebookID, page: page.id).transformed(using: t)
        if let bg = page.background, let image = store.image(bg, notebook: notebookID),
           let turned = image.rotatedQuarter(clockwise: clockwise),
           let name = store.saveAsset(turned, notebook: notebookID) {
            rotated.background = name
        }
        store.saveDrawing(drawing, notebook: notebookID, page: rotated.id)
        store.updateNotebook(notebookID) { nb in
            guard let i = nb.pages.firstIndex(where: { $0.id == page.id }) else { return }
            nb.pages[i] = rotated
        }
        store.removeDrawing(notebook: notebookID, page: page.id)
        if index == 0 { updateThumbnail() }
        Haptics.success()
    }

    func deletePage(at index: Int) {
        guard let nb = notebook, nb.pages.count > 1, nb.pages.indices.contains(index) else { return }
        if index == pageIndex { pending = nil }
        store.deletePage(nb.pages[index].id, in: notebookID)
        if pageIndex >= index, pageIndex > 0 { pageIndex -= 1 }
        pageIndex = min(pageIndex, (notebook?.pages.count ?? 1) - 1)
    }

    func movePage(from index: Int, by offset: Int) {
        flush()
        let target = index + offset
        guard let nb = notebook, nb.pages.indices.contains(index), nb.pages.indices.contains(target) else { return }
        let currentID = nb.pages[pageIndex].id
        store.updateNotebook(notebookID) { $0.pages.swapAt(index, target) }
        pageIndex = notebook?.pages.firstIndex(where: { $0.id == currentID }) ?? pageIndex
    }

    func addPage(_ paper: PaperStyle) {
        flush()
        var newIndex = pageIndex
        store.updateNotebook(notebookID) { nb in
            newIndex = min(pageIndex + 1, nb.pages.count)
            nb.pages.insert(Page(paper: paper), at: newIndex)
        }
        withAnimation(.easeInOut(duration: 0.25)) { pageIndex = newIndex }
        Haptics.success()
    }

    func deleteCurrentPage() {
        guard let page = currentPage, (notebook?.pages.count ?? 0) > 1 else { return }
        pending = nil
        store.deletePage(page.id, in: notebookID)
        pageIndex = min(pageIndex, (notebook?.pages.count ?? 1) - 1)
    }

    /// Scans, Fotos von Buchseiten oder PDF-Seiten werden zu neuen Seiten mit Bild-Hintergrund.
    func addBackgroundPages(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        flush()
        var pages: [Page] = []
        for img in images {
            guard let name = store.saveAsset(img, notebook: notebookID), img.size.width > 0 else { continue }
            let height = Page.defaultWidth * Double(img.size.height / img.size.width)
            pages.append(Page(paper: .blank, background: name, width: Page.defaultWidth, height: height))
        }
        guard !pages.isEmpty else { return }
        var firstNew = pageIndex
        store.updateNotebook(notebookID) { nb in
            // Ist die aktuelle Seite noch leer, wird sie ersetzt.
            let current = nb.pages.indices.contains(pageIndex) ? nb.pages[pageIndex] : nil
            let isEmpty = current.map { $0.background == nil && $0.items.isEmpty && store.loadDrawing(notebook: notebookID, page: $0.id).strokes.isEmpty } ?? false
            if isEmpty {
                nb.pages.remove(at: pageIndex)
                firstNew = pageIndex
            } else {
                firstNew = min(pageIndex + 1, nb.pages.count)
            }
            nb.pages.insert(contentsOf: pages, at: firstNew)
        }
        withAnimation(.easeInOut(duration: 0.25)) { pageIndex = firstNew }
        Haptics.success()
    }

    func importPDF(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: url) else { return }
        var images: [UIImage] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            guard box.width > 0 else { continue }
            let size = CGSize(width: 1600, height: 1600 * box.height / box.width)
            images.append(page.thumbnail(of: size, for: .mediaBox))
        }
        addBackgroundPages(images)
    }

    /// Fügt ein Bild (Foto, Screenshot, KI-Antwort) auf der aktuellen Seite ein.
    func addImage(_ image: UIImage, below rect: CGRect? = nil) {
        guard let page = currentPage, image.size.width > 0,
              let name = store.saveAsset(image, notebook: notebookID) else { return }
        let maxW = page.width * 0.7
        let maxH = page.height * 0.6
        let s = min(maxW / Double(image.size.width), maxH / Double(image.size.height))
        let w = Double(image.size.width) * s
        let h = Double(image.size.height) * s
        var x = (page.width - w) / 2
        var y = (page.height - h) / 2
        if let rect {
            x = min(max(Double(rect.minX), 20), page.width - w - 20)
            y = min(Double(rect.maxY) + 16, page.height - h - 20)
        }
        let item = PageImageItem(asset: name, frame: CGRect(x: x, y: max(y, 20), width: w, height: h))
        store.updateNotebook(notebookID) { nb in
            guard nb.pages.indices.contains(pageIndex) else { return }
            nb.pages[pageIndex].items.append(item)
        }
        Haptics.success()
        // Gleich zum Zurechtrücken anbieten
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            aiMode = false
            geometryTool = nil
            imageEditMode = true
        }
    }

    func insertAnswer(_ text: String) {
        let card = AnswerCardView(text: text).frame(width: 640)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        guard let image = renderer.uiImage else { return }
        addImage(image, below: lastLassoRect)
    }

    func setItems(_ items: [PageImageItem], pageID: UUID) {
        store.updateNotebook(notebookID) { nb in
            guard let i = nb.pages.firstIndex(where: { $0.id == pageID }) else { return }
            nb.pages[i].items = items
        }
    }

    func toggleImageEditMode() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            imageEditMode.toggle()
            if imageEditMode {
                aiMode = false
                geometryTool = nil
            }
        }
        Haptics.tap()
    }

    /// Bild angetippt: direkt in den Bearbeiten-Modus.
    func startImageEditing() {
        guard !imageEditMode else { return }
        toggleImageEditMode()
    }

    func stopImageEditing() {
        guard imageEditMode else { return }
        toggleImageEditMode()
    }

    // MARK: Lineal, Zirkel, Strecke

    func toggleGeometry(_ tool: GeometryTool) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            geometryTool = geometryTool == tool ? nil : tool
            if geometryTool != nil {
                aiMode = false
                imageEditMode = false
            }
        }
        Haptics.tap()
    }

    /// Zwischen »Breite füllen« und »ganze Seite sehen« umschalten.
    func toggleWholePage() {
        wholePage.toggle()
        Haptics.tap()
    }

    // MARK: Buch daneben

    func toggleBook() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            showBook.toggle()
            if !showBook { bookFullScreen = false }
        }
        Haptics.tap()
    }

    func toggleBookFullScreen() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { bookFullScreen.toggle() }
        Haptics.tap()
    }

    /// Speichert die Buch-Adresse für dieses Heft (nil = Zuordnung entfernen).
    func assignBook(_ stored: String?) {
        store.updateNotebook(notebookID) { $0.bookURL = stored }
        Haptics.success()
    }

    /// Merkt sich still die zuletzt gelesene Stelle im zugeordneten Buch.
    func rememberBookPosition(_ stored: String) {
        store.updateNotebook(notebookID) { $0.bookURL = stored }
    }

    /// Ausschnitt aus dem Buch an die KI (öffnet das Frage-Fenster).
    func ask(about image: UIImage, sourcePage: UIImage? = nil, sourceArea: CGRect? = nil) {
        lastLassoRect = nil
        Haptics.success()
        snapshot = LassoSnapshot(image: image, rect: .zero, sourcePage: sourcePage, sourceArea: sourceArea)
    }

    func toggleRuler() {
        rulerActive.toggle()
        Haptics.tap()
    }

    // MARK: KI

    func toggleAIMode() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            aiMode.toggle()
            if aiMode {
                imageEditMode = false
                geometryTool = nil
            }
        }
        Haptics.tap()
    }

    /// Doppeltippen oder Drücken auf dem Apple Pencil.
    func pencilAction(_ action: PencilAction) {
        switch action {
        case .ai:
            toggleAIMode()
        case .eraser:
            ink.toggleEraser()
            Haptics.tap()
        }
    }

    func handleLasso(rect: CGRect, drawing: PKDrawing, pageID: UUID) {
        guard let page = notebook?.pages.first(where: { $0.id == pageID }) else { return }
        let scale = min(3, 1600 / max(rect.width, rect.height))
        let image = PageRenderer.render(page: page, drawing: drawing,
                                        image: { [store, notebookID] in store.image($0, notebook: notebookID) },
                                        rect: rect, scale: scale)
        lastLassoRect = rect
        Haptics.success()
        snapshot = LassoSnapshot(image: image, rect: rect)
    }

    func currentPageImage(scale: CGFloat = 1.4) -> UIImage? {
        guard let page = currentPage else { return nil }
        flush()
        let drawing = host?.canvas.drawing ?? store.loadDrawing(notebook: notebookID, page: page.id)
        return PageRenderer.render(page: page, drawing: drawing,
                                   image: { [store, notebookID] in store.image($0, notebook: notebookID) },
                                   scale: scale)
    }

    // MARK: Export

    func exportPDF() -> URL? {
        flush()
        guard let nb = notebook else { return nil }
        let safe = nb.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).pdf")
        do {
            try PageRenderer.pdf(notebook: nb,
                                 drawing: { [store, notebookID] in store.loadDrawing(notebook: notebookID, page: $0.id) },
                                 image: { [store, notebookID] in store.image($0, notebook: notebookID) },
                                 to: url)
            return url
        } catch {
            return nil
        }
    }

    // MARK: Rückgängig

    func undo() { host?.canvas.undoManager?.undo() }
    func redo() { host?.canvas.undoManager?.redo() }
}

/// Wie eine KI-Antwort auf der Seite aussieht, wenn man sie einfügt.
struct AnswerCardView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("KI-Antwort").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Theme.aiGradient)
            MarkdownText(text: text)
                .font(.system(size: 17))
                .foregroundStyle(Color.black)
        }
        .padding(20)
        .background(Color(red: 0.97, green: 0.96, blue: 1.0), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.aiGradient, lineWidth: 2))
        .environment(\.colorScheme, .light)
    }
}

/// Texterkennung mit Vision (Deutsch und Englisch, auch Handschrift).
enum TextRecognizer {
    static func recognize(_ images: [CGImage]) -> String {
        var lines: [String] = []
        for image in images {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["de-DE", "en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
            for observation in request.results ?? [] {
                if let candidate = observation.topCandidates(1).first {
                    lines.append(candidate.string)
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
