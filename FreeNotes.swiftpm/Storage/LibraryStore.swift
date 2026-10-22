import SwiftUI
import PencilKit
import UIKit

/// Hält Fächer, Hefte und Chats und speichert alles als JSON in „Dokumente/FreeNotes“.
@MainActor
final class LibraryStore: ObservableObject {
    @Published var subjects: [Subject] = []
    @Published var notebooks: [Notebook] = []
    @Published var threads: [ChatThread] = []
    /// Wird erhöht, wenn sich ein Vorschaubild ändert, damit die Cover neu laden.
    @Published private(set) var thumbVersion = 0

    let root: URL
    private var saveTask: Task<Void, Never>?
    private var chatSaveTask: Task<Void, Never>?
    private let imageCache = NSCache<NSString, UIImage>()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("FreeNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Notebooks", isDirectory: true),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: chatAssetsDir, withIntermediateDirectories: true)
        load()
        if subjects.isEmpty && notebooks.isEmpty { seed() }
    }

    // MARK: Pfade

    private var libraryURL: URL { root.appendingPathComponent("library.json") }
    private var chatsURL: URL { root.appendingPathComponent("chats.json") }
    var chatAssetsDir: URL { root.appendingPathComponent("ChatAssets", isDirectory: true) }

    func notebookDir(_ id: UUID) -> URL {
        root.appendingPathComponent("Notebooks/\(id.uuidString)", isDirectory: true)
    }

    private func drawingURL(notebook: UUID, page: UUID) -> URL {
        notebookDir(notebook).appendingPathComponent("\(page.uuidString).drawing")
    }

    private func assetURL(notebook: UUID, name: String) -> URL {
        notebookDir(notebook).appendingPathComponent("assets/\(name)")
    }

    private func thumbURL(notebook: UUID) -> URL {
        notebookDir(notebook).appendingPathComponent("thumb.jpg")
    }

    // MARK: Laden & Speichern

    private func load() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: libraryURL),
           let lib = try? decoder.decode(LibraryData.self, from: data) {
            subjects = lib.subjects
            notebooks = lib.notebooks
        }
        if let data = try? Data(contentsOf: chatsURL),
           let saved = try? decoder.decode([ChatThread].self, from: data) {
            threads = saved
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let lib = LibraryData(subjects: subjects, notebooks: notebooks)
        if let data = try? JSONEncoder().encode(lib) {
            try? data.write(to: libraryURL, options: .atomic)
        }
    }

    private func scheduleChatSave() {
        chatSaveTask?.cancel()
        chatSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self,
                  let data = try? JSONEncoder().encode(self.threads) else { return }
            try? data.write(to: self.chatsURL, options: .atomic)
        }
    }

    private func seed() {
        let math = Subject(name: "Mathe", colorIndex: 0, symbol: "function")
        subjects = [
            math,
            Subject(name: "Deutsch", colorIndex: 1, symbol: "text.book.closed"),
            Subject(name: "Englisch", colorIndex: 5, symbol: "globe.europe.africa"),
            Subject(name: "Biologie", colorIndex: 2, symbol: "leaf"),
        ]
        notebooks = [
            Notebook(title: "Mathe-Heft", subjectID: math.id, colorIndex: 0, paper: .grid, pages: [Page(paper: .grid)])
        ]
        saveNow()
    }

    // MARK: Fächer

    func subject(_ id: UUID?) -> Subject? {
        guard let id else { return nil }
        return subjects.first { $0.id == id }
    }

    func addSubject(_ subject: Subject) {
        subjects.append(subject)
        scheduleSave()
    }

    func updateSubject(_ subject: Subject) {
        guard let i = subjects.firstIndex(where: { $0.id == subject.id }) else { return }
        subjects[i] = subject
        scheduleSave()
    }

    func deleteSubject(_ id: UUID) {
        subjects.removeAll { $0.id == id }
        for i in notebooks.indices where notebooks[i].subjectID == id {
            notebooks[i].subjectID = nil
        }
        scheduleSave()
    }

    // MARK: Hefte

    func notebook(_ id: UUID) -> Notebook? {
        notebooks.first { $0.id == id }
    }

    @discardableResult
    func createNotebook(title: String, subjectID: UUID?, colorIndex: Int, paper: PaperStyle) -> Notebook {
        let name = title.trimmed.isEmpty ? "Neues Heft" : title.trimmed
        let nb = Notebook(title: name, subjectID: subjectID, colorIndex: colorIndex, paper: paper, pages: [Page(paper: paper)])
        notebooks.insert(nb, at: 0)
        scheduleSave()
        return nb
    }

    func updateNotebook(_ id: UUID, _ change: (inout Notebook) -> Void) {
        guard let i = notebooks.firstIndex(where: { $0.id == id }) else { return }
        change(&notebooks[i])
        notebooks[i].modified = Date()
        scheduleSave()
    }

    func deleteNotebook(_ id: UUID) {
        notebooks.removeAll { $0.id == id }
        threads.removeAll { $0.notebookID == id }
        try? FileManager.default.removeItem(at: notebookDir(id))
        scheduleSave()
        scheduleChatSave()
    }

    func deletePage(_ pageID: UUID, in notebookID: UUID) {
        updateNotebook(notebookID) { nb in
            guard nb.pages.count > 1 else { return }
            nb.pages.removeAll { $0.id == pageID }
        }
        try? FileManager.default.removeItem(at: drawingURL(notebook: notebookID, page: pageID))
    }

    // MARK: Zeichnungen

    func loadDrawing(notebook: UUID, page: UUID) -> PKDrawing {
        guard let data = try? Data(contentsOf: drawingURL(notebook: notebook, page: page)),
              let drawing = try? PKDrawing(data: data) else { return PKDrawing() }
        return drawing
    }

    func saveDrawing(_ drawing: PKDrawing, notebook: UUID, page: UUID) {
        try? FileManager.default.createDirectory(at: notebookDir(notebook), withIntermediateDirectories: true)
        try? drawing.dataRepresentation().write(to: drawingURL(notebook: notebook, page: page), options: .atomic)
    }

    // MARK: Bilder

    func saveAsset(_ image: UIImage, notebook: UUID) -> String? {
        let name = UUID().uuidString + ".jpg"
        let url = assetURL(notebook: notebook, name: name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let scaled = image.downscaled(maxSide: 2400)
        guard let data = scaled.jpegData(compressionQuality: 0.85) else { return nil }
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        imageCache.setObject(scaled, forKey: "\(notebook.uuidString)/\(name)" as NSString)
        return name
    }

    func image(_ name: String, notebook: UUID) -> UIImage? {
        let key = "\(notebook.uuidString)/\(name)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let img = UIImage(contentsOfFile: assetURL(notebook: notebook, name: name).path) else { return nil }
        imageCache.setObject(img, forKey: key)
        return img
    }

    func saveThumbnail(_ image: UIImage, notebook: UUID) {
        try? FileManager.default.createDirectory(at: notebookDir(notebook), withIntermediateDirectories: true)
        try? image.jpegData(compressionQuality: 0.8)?.write(to: thumbURL(notebook: notebook), options: .atomic)
        thumbVersion += 1
    }

    func thumbnail(notebook: UUID) -> UIImage? {
        UIImage(contentsOfFile: thumbURL(notebook: notebook).path)
    }

    // MARK: Chats

    func thread(_ id: UUID) -> ChatThread? {
        threads.first { $0.id == id }
    }

    /// Chat-Verlauf eines Hefts (wird bei Bedarf angelegt).
    func threadID(forNotebook id: UUID, title: String) -> UUID {
        if let t = threads.first(where: { $0.notebookID == id }) { return t.id }
        let t = ChatThread(title: title, notebookID: id)
        threads.append(t)
        scheduleChatSave()
        return t.id
    }

    var generalThreads: [ChatThread] {
        threads.filter { $0.notebookID == nil }.sorted { $0.updated > $1.updated }
    }

    func latestGeneralThreadID() -> UUID {
        generalThreads.first?.id ?? newGeneralThread()
    }

    @discardableResult
    func newGeneralThread() -> UUID {
        let t = ChatThread(title: "Neuer Chat")
        threads.append(t)
        scheduleChatSave()
        return t.id
    }

    func deleteThread(_ id: UUID) {
        threads.removeAll { $0.id == id }
        scheduleChatSave()
    }

    func updateThread(_ id: UUID, _ change: (inout ChatThread) -> Void) {
        guard let i = threads.firstIndex(where: { $0.id == id }) else { return }
        change(&threads[i])
        threads[i].updated = Date()
        scheduleChatSave()
    }

    func saveChatImage(_ image: UIImage) -> String? {
        let name = UUID().uuidString + ".jpg"
        guard let data = image.downscaled(maxSide: 1600).jpegData(compressionQuality: 0.85) else { return nil }
        do { try data.write(to: chatAssetsDir.appendingPathComponent(name), options: .atomic) } catch { return nil }
        return name
    }

    func chatImage(_ name: String) -> UIImage? {
        let key = "chat/\(name)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let img = UIImage(contentsOfFile: chatAssetsDir.appendingPathComponent(name).path) else { return nil }
        imageCache.setObject(img, forKey: key)
        return img
    }
}
