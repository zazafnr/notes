import SwiftUI
import PencilKit
import PDFKit

struct LassoSnapshot: Identifiable {
    let id = UUID()
    let image: UIImage
    let rect: CGRect
}

@MainActor
final class EditorModel: ObservableObject {
    let notebookID: UUID
    let store: LibraryStore
    let toolPicker = PKToolPicker()

    @Published var pageIndex = 0
    @Published var aiMode = false
    @Published var showPanel = false
    @Published var snapshot: LassoSnapshot?

    weak var host: PageCanvasHost?
    private var lastLassoRect: CGRect?
    private var pending: (page: UUID, drawing: PKDrawing)?
    private var saveTask: Task<Void, Never>?

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
        flush()
        store.updateNotebook(notebookID) { $0.lastPage = pageIndex }
        updateThumbnail()
        store.saveNow()
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
        flush()
        aiMode = false
        withAnimation(.easeInOut(duration: 0.25)) { pageIndex = index }
        Haptics.tap()
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
    }

    func insertAnswer(_ text: String) {
        let card = AnswerCardView(text: text).frame(width: 640)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        guard let image = renderer.uiImage else { return }
        addImage(image, below: lastLassoRect)
    }

    func removeLastImage() {
        store.updateNotebook(notebookID) { nb in
            guard nb.pages.indices.contains(pageIndex), !nb.pages[pageIndex].items.isEmpty else { return }
            nb.pages[pageIndex].items.removeLast()
        }
    }

    // MARK: KI

    func toggleAIMode() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { aiMode.toggle() }
        Haptics.tap()
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

    func currentPageImage() -> UIImage? {
        guard let page = currentPage else { return nil }
        flush()
        let drawing = host?.canvas.drawing ?? store.loadDrawing(notebook: notebookID, page: page.id)
        return PageRenderer.render(page: page, drawing: drawing,
                                   image: { [store, notebookID] in store.image($0, notebook: notebookID) },
                                   scale: 1.4)
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
