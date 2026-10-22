import SwiftUI
import WebKit
import Combine
import UniformTypeIdentifiers

/// Browser für das Schulbuch (z. B. digi4school) oder ein PDF-Buch.
/// Die Anmeldung passiert direkt hier; die App speichert keine Passwörter, nur das Login-Cookie wie Safari.
@MainActor
final class BookBrowser: ObservableObject {
    static let startURL = URL(string: "https://digi4school.at")!

    let webView: WKWebView
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var title = ""
    @Published var currentURL: URL?

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // Login bleibt erhalten
        config.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.publisher(for: \.canGoBack).receive(on: DispatchQueue.main).assign(to: &$canGoBack)
        webView.publisher(for: \.canGoForward).receive(on: DispatchQueue.main).assign(to: &$canGoForward)
        webView.publisher(for: \.isLoading).receive(on: DispatchQueue.main).assign(to: &$isLoading)
        webView.publisher(for: \.title).map { $0 ?? "" }.receive(on: DispatchQueue.main).assign(to: &$title)
        webView.publisher(for: \.url).receive(on: DispatchQueue.main).assign(to: &$currentURL)
    }

    func open(_ url: URL) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// Bildschirmfoto eines Bereichs (in Web-View-Koordinaten) oder der ganzen sichtbaren Seite.
    func snapshot(of rect: CGRect? = nil) async -> UIImage? {
        let config = WKSnapshotConfiguration()
        if let rect { config.rect = rect }
        return try? await webView.takeSnapshot(configuration: config)
    }
}

/// Speichert PDF-Bücher in der App, damit sie dauerhaft einem Heft zugeordnet werden können.
enum BookFiles {
    static var folder: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FreeNotes/Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Kopiert ein PDF in die App und gibt eine dauerhafte Adresse »book-file:Name.pdf« zurück.
    static func importPDF(from source: URL) -> String? {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let target = folder.appendingPathComponent(source.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        do { try FileManager.default.copyItem(at: source, to: target) } catch { return nil }
        return "book-file:" + source.lastPathComponent
    }

    /// Wandelt gespeicherte Adressen in echte URLs um.
    static func resolve(_ stored: String?) -> URL? {
        guard let stored else { return nil }
        if stored.hasPrefix("book-file:") {
            return folder.appendingPathComponent(String(stored.dropFirst("book-file:".count)))
        }
        return URL(string: stored)
    }

    /// Umgekehrt: aus einer geöffneten URL die dauerhafte Adresse machen.
    static func storable(_ url: URL) -> String {
        if url.isFileURL, url.path.hasPrefix(folder.path) {
            return "book-file:" + url.lastPathComponent
        }
        return url.absoluteString
    }
}

struct BookPanel: View {
    @ObservedObject var model: EditorModel
    @StateObject private var browser = BookBrowser()
    @State private var circling = false
    @State private var showPDFImporter = false
    @State private var didLoad = false

    private var assigned: String? { model.notebook?.bookURL }

    private var isAssigned: Bool {
        guard let assigned, let current = browser.currentURL else { return false }
        return BookFiles.storable(current) == assigned
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack {
                BookWebView(webView: browser.webView)
                if circling {
                    BookLassoView { rect in
                        Task {
                            if let image = await browser.snapshot(of: rect) {
                                circling = false
                                model.ask(about: image)
                            }
                        }
                    }
                    .transition(.opacity)
                }
                if browser.isLoading {
                    ProgressView()
                        .padding(12)
                        .background(.regularMaterial, in: Circle())
                }
            }
            .overlay(alignment: .top) {
                if circling {
                    Text("Kreise eine Aufgabe im Buch ein")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.aiGradient, in: Capsule())
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: circling)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            browser.open(BookFiles.resolve(assigned) ?? BookBrowser.startURL)
        }
        .fileImporter(isPresented: $showPDFImporter, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result, let stored = BookFiles.importPDF(from: url),
                  let local = BookFiles.resolve(stored) else { return }
            browser.open(local)
            model.assignBook(stored)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            Button { browser.webView.goBack() } label: { ToolbarIcon(symbol: "chevron.backward") }
                .disabled(!browser.canGoBack)
            Button { browser.webView.goForward() } label: { ToolbarIcon(symbol: "chevron.forward") }
                .disabled(!browser.canGoForward)
            Button { browser.webView.reload() } label: { ToolbarIcon(symbol: "arrow.clockwise") }

            VStack(alignment: .leading, spacing: 0) {
                Text(browser.title.isEmpty ? "Buch" : browser.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(browser.currentURL?.host ?? (browser.currentURL?.isFileURL == true ? "PDF" : ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)

            Button {
                withAnimation { circling.toggle() }
                Haptics.tap()
            } label: {
                ToolbarIcon(symbol: "sparkles", active: circling, gradient: true)
            }
            .help("Aufgabe im Buch einkreisen und die KI fragen")

            Menu {
                Button {
                    if let url = browser.currentURL { model.assignBook(BookFiles.storable(url)) }
                } label: {
                    Label(isAssigned ? "Ist diesem Heft zugeordnet" : "Diese Seite diesem Heft zuordnen",
                          systemImage: isAssigned ? "pin.fill" : "pin")
                }
                .disabled(browser.currentURL == nil)
                Button {
                    browser.open(BookFiles.resolve(assigned) ?? BookBrowser.startURL)
                } label: { Label("Zugeordnetes Buch öffnen", systemImage: "book") }
                .disabled(assigned == nil)
                Button { browser.open(BookBrowser.startURL) } label: {
                    Label("digi4school öffnen", systemImage: "globe")
                }
                Button { showPDFImporter = true } label: {
                    Label("PDF-Buch öffnen …", systemImage: "doc.richtext")
                }
                Divider()
                Button {
                    Task { if let image = await browser.snapshot() { model.addImage(image) } }
                } label: { Label("Sichtbare Buchseite ins Heft", systemImage: "square.and.arrow.down.on.square") }
                Button {
                    Task { if let image = await browser.snapshot() { model.addBackgroundPages([image]) } }
                } label: { Label("Als neue Heftseite", systemImage: "doc.badge.plus") }
                if assigned != nil {
                    Divider()
                    Button(role: .destructive) { model.assignBook(nil) } label: {
                        Label("Zuordnung entfernen", systemImage: "pin.slash")
                    }
                }
            } label: {
                ToolbarIcon(symbol: isAssigned ? "pin.circle.fill" : "ellipsis.circle")
            }

            Button { model.toggleBook() } label: { ToolbarIcon(symbol: "xmark") }
        }
        .buttonStyle(PressableStyle())
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct BookWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Leuchtende Schleife über dem Buch; meldet das umschlossene Rechteck.
struct BookLassoView: UIViewRepresentable {
    var onRect: (CGRect) -> Void

    func makeUIView(context: Context) -> LassoOverlayView {
        let view = LassoOverlayView()
        view.onComplete = { [weak view] path in
            guard let view else { return }
            let rect = path.bounds.insetBy(dx: -12, dy: -12).intersection(view.bounds)
            guard !rect.isNull, rect.width > 10, rect.height > 10 else { return }
            onRect(rect)
        }
        return view
    }

    func updateUIView(_ uiView: LassoOverlayView, context: Context) {}
}
