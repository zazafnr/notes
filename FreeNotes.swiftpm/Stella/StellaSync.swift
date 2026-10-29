import SwiftUI
import PencilKit

/// Verbindung zu Stella (persönlicher Assistent auf dem eigenen Server).
/// Stella holt die Buchseite einer HÜ, löst sie und legt den Heft-Text bereit.
/// FreeNotes holt ihn ab und schreibt ihn in der eigenen Handschrift ins passende Fach-Heft.
@MainActor
final class StellaSync: ObservableObject {
    static let shared = StellaSync()

    @Published var server: String { didSet { defaults.set(server, forKey: "stella.server") } }
    @Published var email: String { didSet { defaults.set(email, forKey: "stella.email") } }
    @Published var autoSync: Bool { didSet { defaults.set(autoSync, forKey: "stella.autoSync") } }
    @Published private(set) var isConnected: Bool
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isSyncing = false
    /// Kurzer Hinweis oben im Bildschirm (»Stella hat … ins Heft geschrieben«).
    @Published var notice: String?
    /// Ist gerade ein Heft offen? Dann nichts schreiben – der Editor würde die Seite sonst überschreiben.
    var editorOpen = false

    private let defaults = UserDefaults.standard
    private static let tokenAccount = "stella.token"

    /// Bereits geschriebene Einträge – falls die Bestätigung an Stella scheitert, nicht doppelt schreiben.
    private var written: Set<String> {
        get { Set(defaults.stringArray(forKey: "stella.written") ?? []) }
        set { defaults.set(Array(newValue.suffix(300)), forKey: "stella.written") }
    }

    init() {
        server = defaults.string(forKey: "stella.server") ?? ""
        email = defaults.string(forKey: "stella.email") ?? ""
        autoSync = defaults.object(forKey: "stella.autoSync") as? Bool ?? true
        isConnected = !(Keychain.read(account: Self.tokenAccount) ?? "").isEmpty
    }

    // MARK: Verbinden

    func connect(server rawServer: String, email: String, password: String) async throws {
        guard let base = StellaLogic.normalizedServer(rawServer) else {
            throw StellaError.message("Bitte die Adresse deines Stella-Servers eingeben, z. B. stella.deinedomain.at.")
        }
        var request = URLRequest(url: base.appendingPathComponent("api/auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email.trimmed, "password": password, "device": "FreeNotes (iPad)",
        ])
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            throw StellaError.message(StellaLogic.errorMessage(from: data, status: status))
        }
        Keychain.write(token, account: Self.tokenAccount)
        server = base.absoluteString
        self.email = email.trimmed
        isConnected = true
        lastError = nil
    }

    func disconnect() {
        Keychain.write("", account: Self.tokenAccount)
        isConnected = false
        lastSync = nil
    }

    private func send(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard let base = StellaLogic.normalizedServer(server),
              let token = Keychain.read(account: Self.tokenAccount), !token.isEmpty else {
            throw StellaError.message("Nicht mit Stella verbunden.")
        }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            disconnect()
            throw StellaError.message("Stella-Anmeldung abgelaufen – bitte in den Einstellungen neu verbinden.")
        }
        guard (200..<300).contains(status) else { throw StellaError.message(StellaLogic.errorMessage(from: data, status: status)) }
        return data
    }

    // MARK: Abholen & schreiben

    /// Holt gelöste HÜs und schreibt sie in die Hefte.
    /// Nur aufrufen, solange kein Heft geöffnet ist (sonst würde der Editor die Seite überschreiben).
    func sync(store: LibraryStore, manual: Bool = false) async {
        guard isConnected, !isSyncing, !editorOpen, manual || autoSync else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let entries = try JSONDecoder().decode([StellaEntry].self, from: try await send("api/notes/inbox"))
            var titles: [String] = []
            for entry in entries {
                if editorOpen { break }
                var notebookTitle = ""
                var pageNumber = 0
                if !written.contains(entry.id) {
                    let (notebookID, page) = write(entry, store: store)
                    notebookTitle = store.notebook(notebookID)?.title ?? ""
                    pageNumber = page
                    written.insert(entry.id)
                    titles.append(entry.title)
                }
                _ = try? await send("api/notes/inbox/\(entry.id)/ack", method: "POST",
                                    body: ["notebook": notebookTitle, "page": pageNumber])
            }
            store.saveNow()
            lastSync = Date()
            lastError = nil
            if titles.count == 1 {
                notice = "Stella hat \(titles[0]) in dein Heft geschrieben"
            } else if titles.count > 1 {
                notice = "Stella hat \(titles.count) HÜs in deine Hefte geschrieben"
            } else if manual {
                notice = "Nichts Neues von Stella"
            }
            if !titles.isEmpty { Haptics.success() }
        } catch {
            lastError = error.localizedDescription
            if manual { notice = lastError }
        }
    }

    /// Schreibt einen Eintrag ins Fach-Heft: unter das zuletzt Geschriebene, sonst auf neue Seiten.
    /// Gibt das Heft und die (1-basierte) Seitennummer zurück, auf der die HÜ beginnt.
    private func write(_ entry: StellaEntry, store: LibraryStore) -> (UUID, Int) {
        let notebookID = notebook(for: entry.subject ?? "Stella", store: store)
        guard let notebook = store.notebook(notebookID) else { return (notebookID, 0) }
        let hw = HandwritingStore.shared
        let text = StellaLogic.notebookText(for: entry)
        var seed = UInt64(entry.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ UInt64($1.value)) & 0xFFFF_FFFF })
        var remaining: String? = text
        var firstPage: Int?

        // 1) Auf der letzten Seite weiter, wenn dort noch genug Platz ist (keine Scan-Seite)
        if let last = notebook.pages.last, last.background == nil {
            var drawing = store.loadDrawing(notebook: notebookID, page: last.id)
            let ruling = HWRuling.forPaper(last.paper, size: last.size)
            let bottom = Self.contentBottom(of: last, drawing: drawing)
            let start = ruling.baseline(below: bottom, gapLines: 2)
            if start <= ruling.bottom - ruling.lineHeight * 4 {
                let xh = ruling.xHeight(scale: hw.size)
                let layout = HandwritingLayout.layout(text, font: hw.font, style: hw.style(xHeight: xh),
                                                      ruling: ruling, startBaseline: start, seed: seed)
                drawing.strokes.append(contentsOf: Self.ink(layout.strokes, xHeight: xh))
                store.saveDrawing(drawing, notebook: notebookID, page: last.id)
                remaining = layout.overflow
                firstPage = notebook.pages.count - 1
                seed &+= 1
            }
        }

        // 2) Rest auf neue Seiten am Ende des Hefts
        let paper: PaperStyle = notebook.paper == .blank ? .lined : notebook.paper
        var newPages: [Page] = []
        while let rest = remaining, !rest.trimmed.isEmpty, newPages.count < 10 {
            let page = Page(paper: paper)
            let ruling = HWRuling.forPaper(paper, size: page.size)
            let xh = ruling.xHeight(scale: hw.size)
            let layout = HandwritingLayout.layout(rest, font: hw.font, style: hw.style(xHeight: xh), ruling: ruling, seed: seed)
            seed &+= 1
            var drawing = PKDrawing()
            drawing.strokes = Self.ink(layout.strokes, xHeight: xh)
            store.saveDrawing(drawing, notebook: notebookID, page: page.id)
            newPages.append(page)
            if layout.strokes.isEmpty { break }
            remaining = layout.overflow
        }

        let startIndex = firstPage ?? notebook.pages.count
        store.updateNotebook(notebookID) { nb in
            nb.pages.append(contentsOf: newPages)
            // Beim Öffnen direkt bei der HÜ landen
            nb.lastPage = min(startIndex, max(nb.pages.count - 1, 0))
        }
        return (notebookID, startIndex + 1)
    }

    /// Heft zum Fach finden – oder anlegen (mit Fach, falls es das noch nicht gibt).
    private func notebook(for subjectName: String, store: LibraryStore) -> UUID {
        if let id = StellaLogic.notebookID(forSubject: subjectName, subjects: store.subjects, notebooks: store.notebooks) {
            return id
        }
        let subject: Subject
        if let existing = store.subjects.first(where: { StellaLogic.sameSubject($0.name, subjectName) }) {
            subject = existing
        } else {
            let color = subjectName.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Theme.subjectColors.count
            subject = Subject(name: subjectName, colorIndex: color, symbol: "book.closed")
            store.addSubject(subject)
        }
        return store.createNotebook(title: "\(subject.name)-Heft", subjectID: subject.id,
                                    colorIndex: subject.colorIndex, paper: .lined).id
    }

    private static func contentBottom(of page: Page, drawing: PKDrawing) -> Double? {
        var bottom: CGFloat?
        if !drawing.strokes.isEmpty { bottom = drawing.bounds.maxY }
        for item in page.items { bottom = max(bottom ?? 0, item.boundingBox.maxY) }
        return bottom.map(Double.init)
    }

    private static func ink(_ strokes: [HWStroke], xHeight: Double) -> [PKStroke] {
        HandwritingInk.pkStrokes(strokes, color: HandwritingInk.color,
                                 width: HandwritingInk.strokeWidth(xHeight: xHeight), xHeight: xHeight)
    }
}

enum StellaError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

// MARK: - Hinweis oben

struct StellaToast: ViewModifier {
    @ObservedObject private var stella = StellaSync.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let notice = stella.notice {
                    Label(notice, systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Theme.aiGradient, in: Capsule())
                        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onTapGesture { stella.notice = nil }
                        .task(id: notice) {
                            try? await Task.sleep(nanoseconds: 4_000_000_000)
                            stella.notice = nil
                        }
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: stella.notice)
    }
}

extension View {
    func stellaToast() -> some View { modifier(StellaToast()) }
}
