import SwiftUI
import WebKit
import Combine
import UniformTypeIdentifiers

/// Browser für das Schulbuch (z. B. digi4school) oder ein PDF-Buch.
/// Die Anmeldung passiert direkt hier; die App speichert keine Passwörter, nur das Login-Cookie wie Safari.
/// Seiten, die ein neues Fenster öffnen (digi4school »Öffnen«), erscheinen als weitere Ebene im selben Fenster.
@MainActor
final class BookBrowser: NSObject, ObservableObject, WKUIDelegate, WKNavigationDelegate {
    static let startURL = URL(string: "https://digi4school.at")!

    private let mainWebView: WKWebView
    /// Neue Fenster, die eine Seite geöffnet hat (oberstes wird angezeigt).
    @Published private(set) var popups: [WKWebView] = []
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var title = ""
    @Published var currentURL: URL?

    private var bindings: Set<AnyCancellable> = []

    /// Das gerade sichtbare Fenster.
    var webView: WKWebView { popups.last ?? mainWebView }

    /// Zurück geht auch aus einem neuen Fenster wieder zur Bücherliste.
    var canNavigateBack: Bool { canGoBack || !popups.isEmpty }

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // Login bleibt erhalten
        config.allowsInlineMediaPlayback = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Manche Seiten erkennen Browser am »Safari« im User-Agent.
        config.applicationNameForUserAgent = "Version/18.0 Mobile/15E148 Safari/604.1"
        mainWebView = WKWebView(frame: .zero, configuration: config)
        super.init()
        configure(mainWebView)
        bind(mainWebView)
    }

    private func configure(_ web: WKWebView) {
        web.uiDelegate = self
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = true
    }

    /// Anzeige (Titel, Zurück, Laden) folgt immer dem sichtbaren Fenster.
    private func bind(_ web: WKWebView) {
        bindings.removeAll()
        web.publisher(for: \.canGoBack).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canGoBack = $0 }.store(in: &bindings)
        web.publisher(for: \.canGoForward).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canGoForward = $0 }.store(in: &bindings)
        web.publisher(for: \.isLoading).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isLoading = $0 }.store(in: &bindings)
        web.publisher(for: \.title).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.title = $0 ?? "" }.store(in: &bindings)
        web.publisher(for: \.url).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.currentURL = $0 }.store(in: &bindings)
    }

    func open(_ url: URL) {
        closeAllPopups()
        if url.isFileURL {
            mainWebView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            mainWebView.load(URLRequest(url: url))
        }
    }

    func goBack() {
        if webView.canGoBack {
            webView.goBack()
        } else if let top = popups.last {
            close(top)
        }
    }

    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    private func close(_ popup: WKWebView) {
        popup.stopLoading()
        popups.removeAll { $0 === popup }
        bind(webView)
    }

    private func closeAllPopups() {
        popups.forEach { $0.stopLoading() }
        popups.removeAll()
        bind(mainWebView)
    }

    // MARK: Neue Fenster (target="_blank", window.open)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: webView.bounds, configuration: configuration)
        configure(popup)
        popups.append(popup)
        bind(popup)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        close(webView)
    }

    // MARK: Hinweise der Seite (alert/confirm) anzeigen, sonst bleibt sie hängen

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        _ = await presentAlert(message: message, confirm: false)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await presentAlert(message: message, confirm: true)
    }

    private func presentAlert(message: String, confirm: Bool) async -> Bool {
        guard let presenter = webView.window?.rootViewController?.topMost else { return confirm }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in continuation.resume(returning: true) })
            if confirm {
                alert.addAction(UIAlertAction(title: "Abbrechen", style: .cancel) { _ in continuation.resume(returning: false) })
            }
            presenter.present(alert, animated: true)
        }
    }

    /// Bildschirmfoto eines Bereichs (in Web-View-Koordinaten) oder der ganzen sichtbaren Seite.
    func snapshot(of rect: CGRect? = nil) async -> UIImage? {
        let config = WKSnapshotConfiguration()
        if let rect { config.rect = rect }
        // Doppelte Auflösung, damit Text auf der Heftseite scharf bleibt
        config.snapshotWidth = NSNumber(value: Double((rect?.width ?? webView.bounds.width) * 2))
        return try? await webView.takeSnapshot(configuration: config)
    }
}

extension UIViewController {
    /// Oberster angezeigter Controller (für Hinweis-Fenster).
    var topMost: UIViewController {
        presentedViewController?.topMost ?? self
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

    /// Erkennt das Buch unabhängig von der Seite: Host + die ersten zwei Pfadteile
    /// (z. B. »a.digi4school.at/ebook/1234«) oder der Dateiname eines PDF-Buchs.
    static func bookKey(_ stored: String?) -> String? {
        guard let stored else { return nil }
        if stored.hasPrefix("book-file:") { return stored }
        guard let url = URL(string: stored), let host = url.host else { return stored }
        let parts = url.pathComponents.filter { $0 != "/" }.prefix(2)
        return ([host] + parts).joined(separator: "/")
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

    /// Ist das gerade offene Buch (egal welche Seite) diesem Heft zugeordnet?
    private var isAssigned: Bool {
        guard let assigned, let current = browser.currentURL else { return false }
        return BookFiles.bookKey(BookFiles.storable(current)) == BookFiles.bookKey(assigned)
    }

    /// Seite einfügen und das Heft zeigen.
    private func addPage(_ part: PageCropper.Part) {
        Task {
            guard let shot = await browser.snapshot() else { return }
            model.addBackgroundPages([PageCropper.crop(shot, part: part)])
            if model.bookFullScreen { model.toggleBookFullScreen() }
        }
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
                                // Ganze Buchseite merken: Damit kann die Aufgabe später direkt auf der Seite im Heft ausgefüllt werden
                                let viewSize = browser.webView.bounds.size
                                let page = await browser.snapshot().map { PageCropper.page(containing: rect, viewSize: viewSize, in: $0) }
                                model.ask(about: image, sourcePage: page?.image, sourceArea: page?.area)
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
        .onChange(of: browser.currentURL) { _, url in
            // Im zugeordneten Buch die aktuelle Seite merken, damit es dort wieder aufgeht
            guard let url, isAssigned else { return }
            let stored = BookFiles.storable(url)
            if stored != assigned { model.rememberBookPosition(stored) }
        }
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
            Button { browser.goBack() } label: { ToolbarIcon(symbol: "chevron.backward") }
                .disabled(!browser.canNavigateBack)
            Button { browser.goForward() } label: { ToolbarIcon(symbol: "chevron.forward") }
                .disabled(!browser.canGoForward)
            Button { browser.reload() } label: { ToolbarIcon(symbol: "arrow.clockwise") }

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
                    Label(isAssigned ? "Buch ist diesem Heft zugeordnet" : "Dieses Buch diesem Heft zuordnen",
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
                Section("Als neue Heftseite zum Beschreiben") {
                    Button { addPage(.left) } label: { Label("Linke Buchseite", systemImage: "rectangle.lefthalf.filled") }
                    Button { addPage(.right) } label: { Label("Rechte Buchseite", systemImage: "rectangle.righthalf.filled") }
                    Button { addPage(.spread) } label: { Label("Doppelseite (quer)", systemImage: "rectangle.split.2x1") }
                }
                Button {
                    Task { if let image = await browser.snapshot() { model.addImage(image) } }
                } label: { Label("Sichtbaren Ausschnitt als Bild einfügen", systemImage: "photo.badge.plus") }
                if assigned != nil {
                    Divider()
                    Button(role: .destructive) { model.assignBook(nil) } label: {
                        Label("Zuordnung entfernen", systemImage: "pin.slash")
                    }
                }
            } label: {
                ToolbarIcon(symbol: isAssigned ? "pin.circle.fill" : "ellipsis.circle")
            }

            Button { model.toggleBookFullScreen() } label: {
                ToolbarIcon(symbol: model.bookFullScreen ? "rectangle.split.2x1" : "arrow.up.left.and.arrow.down.right")
            }
            .help(model.bookFullScreen ? "Buch und Heft nebeneinander" : "Buch im Vollbild")

            Button { model.toggleBook() } label: { ToolbarIcon(symbol: "xmark") }
        }
        .buttonStyle(PressableStyle())
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Zeigt das gerade aktive Fenster (Hauptseite oder ein neu geöffnetes Buch).
struct BookWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground
        embed(in: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        embed(in: container)
    }

    private func embed(in container: UIView) {
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }
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
