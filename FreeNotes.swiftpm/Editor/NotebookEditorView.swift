import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import VisionKit

struct NotebookEditorView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AISettings
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: EditorModel
    @StateObject private var chat: ChatController

    @State private var showPhotos = false
    @State private var photoItem: PhotosPickerItem?
    @State private var photoAsPage = false
    @State private var showScanner = false
    @State private var showCamera = false
    @State private var showImporter = false
    @State private var showPages = false
    @State private var confirmDelete = false
    @State private var shareURL: ShareItem?
    @State private var totalWidth: CGFloat = 1000
    @State private var writeRequest: WriteRequest?
    @State private var worksheet: WorksheetRequest?

    init(notebookID: UUID, store: LibraryStore, settings: AISettings) {
        _model = StateObject(wrappedValue: EditorModel(notebookID: notebookID, store: store))
        let nb = store.notebook(notebookID)
        let threadID = store.threadID(forNotebook: notebookID, title: nb?.title ?? "Heft")
        _chat = StateObject(wrappedValue: ChatController(store: store, settings: settings, threadID: threadID,
                                                         subject: store.subject(nb?.subjectID)?.name))
    }

    var body: some View {
        ZStack(alignment: .top) {
            EditorBackdrop(tint: Theme.color(model.notebook?.colorIndex ?? 0))

            if let page = model.currentPage {
                PageCanvas(model: model, ink: model.ink, store: store, page: page, fingerDrawing: settings.fingerDrawing,
                           flipDirection: settings.flipDirection, pencilAction: settings.pencilAction)
                    .id(page.id)
                    .ignoresSafeArea(edges: .bottom)
            }

            VStack(spacing: 10) {
                topBar
                if model.aiMode {
                    aiHint.transition(.move(edge: .top).combined(with: .opacity))
                }
                if model.imageEditMode {
                    imageHint.transition(.move(edge: .top).combined(with: .opacity))
                }
                if let tool = model.geometryTool {
                    hint(tool.hint, symbol: tool.symbol) { model.toggleGeometry(tool) }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
        }
        .overlay(alignment: .leading) {
            sideTools
                .padding(.leading, 12)
        }
        .overlay(alignment: .trailing) {
            if model.showPanel {
                AIPanelView(chat: chat, title: model.notebook?.title ?? "KI",
                            onClose: { model.showPanel = false },
                            onInsert: { answer, question, mode in insert(answer, question: question, mode: mode) },
                            pageImage: { model.currentPageImage() })
                    .frame(width: 420)
                    .glass(cornerRadius: 26)
                    .padding(.trailing, 12)
                    .padding(.top, 70)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if let status = model.writing {
                WritingStatusBar(model: model, status: status)
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.writing)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: model.showPanel)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.aiMode)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.imageEditMode)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.geometryTool)
        .padding(.leading, model.showBook && !model.bookFullScreen ? bookWidth : 0)
        .overlay(alignment: .leading) {
            if model.showBook {
                HStack(spacing: 0) {
                    BookPanel(model: model)
                    if !model.bookFullScreen {
                        Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1)
                    }
                }
                .frame(width: model.bookFullScreen ? totalWidth : bookWidth)
                .transition(.move(edge: .leading))
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { totalWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in totalWidth = w }
            }
        }
        .onDrop(of: [.image], isTargeted: nil) { providers in
            let model = model
            var accepted = false
            for provider in providers where provider.canLoadObject(ofClass: UIImage.self) {
                accepted = true
                _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                    guard let image = object as? UIImage else { return }
                    Task { @MainActor in model.addImage(image) }
                }
            }
            return accepted
        }
        .sheet(item: $model.snapshot) { snap in
            AskSheet(snapshot: snap,
                     isLatin: QuickAction.isLatin([model.notebook?.title, store.subject(model.notebook?.subjectID)?.name]),
                     onSend: { display, prompt in
                         chat.send(display: display, prompt: prompt, images: [snap.image], sourcePage: snap.sourcePage,
                                   sourceArea: snap.sourceArea, sourcePageID: snap.pageID)
                         model.aiMode = false
                         model.showPanel = true
                     },
                     onFill: {
                         model.aiMode = false
                         openWorksheet(solutions: nil, bookPage: snap.sourcePage, pageID: snap.pageID,
                                       area: snap.sourceArea, taskImage: snap.image)
                     })
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    if photoAsPage { model.addBackgroundPages([img]) } else { model.addImage(img) }
                }
                photoItem = nil
                photoAsPage = false
            }
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScannerView { images in
                showScanner = false
                model.addBackgroundPages(images)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                if let image { model.addBackgroundPages([image]) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            if url.pathExtension.lowercased() == "pdf" {
                model.importPDF(url)
            } else {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), let img = UIImage(data: data) { model.addImage(img) }
            }
        }
        .sheet(item: $writeRequest) { request in
            HandwritingWriteSheet(model: model, request: request) {
                if let source = request.worksheetSource {
                    openWorksheet(solutions: request.answer, bookPage: source.bookPage, pageID: source.pageID,
                                  area: source.area)
                }
            }
        }
        .sheet(item: $worksheet) { request in
            WorksheetFillSheet(model: model, solutions: request.solutions, fromBook: request.fromBook,
                               taskArea: request.taskArea, taskImage: request.taskImage,
                               subject: store.subject(model.notebook?.subjectID)?.name) { text in
                // Keine Lücken auf der Seite: Lösung stattdessen wie im Heft auf eine neue Seite schreiben
                writeRequest = WriteRequest(answer: text)
            }
        }
        .sheet(isPresented: $showPages) {
            PageOverviewView(model: model)
        }
        .sheet(item: $shareURL) { item in
            ShareSheet(items: [item.url])
        }
        .confirmationDialog("Diese Seite löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Seite löschen", role: .destructive) { model.deleteCurrentPage() }
        }
        .onDisappear { model.close() }
        .statusBarHidden(false)
    }

    // MARK: Werkzeugleiste

    /// Buch und Heft teilen sich den Bildschirm 50/50.
    private var bookWidth: CGFloat { max(totalWidth / 2, 320) }

    /// KI-Antwort ins Heft: in Handschrift, aufs Arbeitsblatt oder als Karte.
    private func insert(_ answer: ChatMessage, question: ChatMessage?, mode: InsertMode) {
        switch mode {
        case .handwriting:
            let images = question?.images.compactMap { store.chatImage($0) } ?? []
            var request = WriteRequest(answer: answer.text, question: question.map { $0.prompt ?? $0.text }, images: images)
            let source = worksheetSource(for: question)
            request.worksheetSource = source
            request.canFillWorksheet = source != nil
            request.prefersWorksheet = source.map { $0.bookPage != nil || pageLooksLikeWorksheet($0.pageID) } ?? false
            writeRequest = request
        case .worksheet:
            let source = worksheetSource(for: question)
            openWorksheet(solutions: answer.text, bookPage: source?.bookPage, pageID: source?.pageID,
                          area: source?.area)
        case .card:
            model.insertAnswer(answer.text)
        }
    }

    /// Woher die Aufgabe stammt (Buchseite oder eingekreist auf einer Heftseite).
    private func worksheetSource(for question: ChatMessage?) -> WorksheetSource? {
        guard let question else { return nil }
        if let name = question.sourcePage, let page = store.chatImage(name) {
            return WorksheetSource(bookPage: page, pageID: nil, area: question.sourceArea)
        }
        if let id = question.sourcePageID, model.notebook?.pages.contains(where: { $0.id == id }) == true {
            return WorksheetSource(bookPage: nil, pageID: id, area: question.sourceArea)
        }
        return nil
    }

    /// Seite mit Scan oder Bild: Antworten gehören dort hinein, nicht darunter.
    private func pageLooksLikeWorksheet(_ id: UUID?) -> Bool {
        guard let id, let page = model.notebook?.pages.first(where: { $0.id == id }) else { return false }
        return page.background != nil || !page.items.isEmpty
    }

    /// Zettel ausfüllen: Buchseite einfügen bzw. zur Seite mit der Aufgabe blättern, dann die Felder suchen.
    private func openWorksheet(solutions: String?, bookPage: UIImage?, pageID: UUID?, area: CGRect?,
                               taskImage: UIImage? = nil) {
        if let bookPage {
            model.addBackgroundPages([bookPage])
        } else if let pageID, let index = model.notebook?.pages.firstIndex(where: { $0.id == pageID }) {
            model.goTo(index)
        }
        let request = WorksheetRequest(solutions: solutions, fromBook: bookPage != nil, taskArea: area, taskImage: taskImage)
        // Kurz warten, bis das vorige Fenster zu ist (zwei Fenster gleichzeitig gehen nicht)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 550_000_000)
            worksheet = request
        }
    }

    /// Passt sich der Breite an: mit Titel, ohne Titel oder in zwei Reihen.
    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                backPill(showTitle: true)
                Spacer(minLength: 0)
                toolsPill(compact: false)
                pageControls(compact: false)
                actionsPill
            }
            HStack(spacing: 10) {
                backPill(showTitle: false)
                Spacer(minLength: 0)
                toolsPill(compact: false)
                pageControls(compact: true)
                actionsPill
            }
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    backPill(showTitle: true)
                    Spacer(minLength: 0)
                    pageControls(compact: true)
                    actionsPill
                }
                toolsPill(compact: false)
            }
        }
        .buttonStyle(PressableStyle())
    }

    private func backPill(showTitle: Bool) -> some View {
        HStack(spacing: 4) {
            Button {
                model.close()
                dismiss()
            } label: { ToolbarIcon(symbol: "chevron.left") }

            if showTitle {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.notebook?.title ?? "")
                        .font(.headline)
                        .lineLimit(1)
                    if let subject = store.subject(model.notebook?.subjectID) {
                        Text(subject.name)
                            .font(.caption)
                            .foregroundStyle(Theme.color(subject.colorIndex))
                    }
                }
                .frame(maxWidth: 180, alignment: .leading)
                .padding(.trailing, 10)
            }
        }
        .padding(4)
        .glass(cornerRadius: 24)
    }

    /// Rückgängig, Stifte, Farbe (ersetzt Apples Werkzeugleiste unten).
    private func toolsPill(compact: Bool) -> some View {
        HStack(spacing: 2) {
            Button { model.undo() } label: { ToolbarIcon(symbol: "arrow.uturn.backward") }
            Button { model.redo() } label: { ToolbarIcon(symbol: "arrow.uturn.forward") }
            Divider().frame(height: 24).padding(.horizontal, 4)
            InkToolbar(ink: model.ink, compact: compact)
        }
        .padding(4)
        .glass(cornerRadius: 24)
    }

    private var actionsPill: some View {
        HStack(spacing: 2) {
            insertMenu

            Button { model.toggleAIMode() } label: {
                ToolbarIcon(symbol: "sparkles", active: model.aiMode, gradient: true)
                    .symbolEffect(.bounce, value: model.aiMode)
            }
            .help("KI-Kreis: Aufgabe einkreisen")

            Button { model.showPanel.toggle() } label: {
                ToolbarIcon(symbol: "bubble.left.and.text.bubble.right", active: model.showPanel)
            }

            Button { model.toggleBook() } label: {
                ToolbarIcon(symbol: "book", active: model.showBook)
            }
            .help("Buch daneben öffnen")

            Menu {
                Section {
                    Button { writeRequest = WriteRequest(answer: "") } label: {
                        Label("Text in meiner Handschrift schreiben", systemImage: "pencil.and.scribble")
                    }
                    Button { worksheet = WorksheetRequest(solutions: nil) } label: {
                        Label("Zettel mit KI ausfüllen", systemImage: "doc.text.viewfinder")
                    }
                }
                Section {
                    Button { model.rotatePage(at: model.pageIndex, clockwise: false) } label: {
                        Label("Seite nach links drehen", systemImage: "rotate.left")
                    }
                    Button { model.rotatePage(at: model.pageIndex, clockwise: true) } label: {
                        Label("Seite nach rechts drehen", systemImage: "rotate.right")
                    }
                }
                Button {
                    if let url = model.exportPDF() { shareURL = ShareItem(url: url) }
                } label: { Label("Als PDF teilen", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Seite löschen", systemImage: "trash")
                }
                .disabled((model.notebook?.pages.count ?? 0) < 2)
            } label: { ToolbarIcon(symbol: "ellipsis.circle") }
        }
        .padding(4)
        .glass(cornerRadius: 24)
    }

    private func pageControls(compact: Bool) -> some View {
        let count = model.notebook?.pages.count ?? 0
        return HStack(spacing: 2) {
            if !compact {
                Button { model.goTo(model.pageIndex - 1) } label: { ToolbarIcon(symbol: "chevron.up") }
                    .disabled(model.pageIndex == 0)
            }
            Button { showPages = true } label: {
                Text("\(model.pageIndex + 1) / \(count)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .contentTransition(.numericText())
                    .frame(minWidth: compact ? 44 : 52, minHeight: 40)
            }
            if !compact {
                Button { model.goTo(model.pageIndex + 1) } label: { ToolbarIcon(symbol: "chevron.down") }
                    .disabled(model.pageIndex >= count - 1)
            }
            Button { model.toggleWholePage() } label: {
                ToolbarIcon(symbol: model.wholePage ? "arrow.left.and.right.square" : "rectangle.portrait.arrowtriangle.2.inward")
            }
            .help(model.wholePage ? "Breite füllen" : "Ganze Seite zeigen")
            Menu {
                ForEach(PaperStyle.allCases) { style in
                    Button { model.addPage(style) } label: { Label("Neue Seite: \(style.title)", systemImage: style.symbol) }
                }
            } label: { ToolbarIcon(symbol: "plus.rectangle.on.rectangle") }
        }
        .padding(4)
        .glass(cornerRadius: 24)
    }

    private var insertMenu: some View {
        Menu {
            Button { photoAsPage = false; showPhotos = true } label: { Label("Foto oder Screenshot einfügen", systemImage: "photo.on.rectangle") }
            Button { photoAsPage = true; showPhotos = true } label: { Label("Foto als ganze Seite (z. B. Buchseite)", systemImage: "doc.richtext") }
            Button {
                if let img = UIPasteboard.general.image { model.addImage(img) }
            } label: { Label("Bild aus Zwischenablage", systemImage: "doc.on.clipboard") }
            .disabled(!UIPasteboard.general.hasImages)
            Divider()
            Button {
                if VNDocumentCameraViewController.isSupported { showScanner = true } else { showCamera = true }
            } label: { Label("Seite scannen", systemImage: "doc.viewfinder") }
            Button { showImporter = true } label: { Label("PDF oder Datei importieren", systemImage: "doc.badge.plus") }
        } label: { ToolbarIcon(symbol: "photo.badge.plus") }
    }

    /// Senkrechte Leiste links: Lineal, Zirkel, Strecke, Bilder bearbeiten.
    private var sideTools: some View {
        VStack(spacing: 2) {
            Button { model.toggleRuler() } label: {
                ToolbarIcon(symbol: "ruler", active: model.rulerActive)
            }
            .help("Lineal")
            ForEach(GeometryTool.allCases) { tool in
                Button { model.toggleGeometry(tool) } label: {
                    ToolbarIcon(symbol: tool.symbol, active: model.geometryTool == tool)
                }
                .help(tool.title)
            }
            Divider().frame(width: 28).padding(.vertical, 4)
            Button { model.toggleImageEditMode() } label: {
                ToolbarIcon(symbol: "photo.on.rectangle.angled", active: model.imageEditMode)
            }
            .disabled(model.currentPage?.items.isEmpty ?? true)
            .help("Bilder verschieben, skalieren, drehen")
        }
        .padding(4)
        .glass(cornerRadius: 24)
        .buttonStyle(PressableStyle())
    }

    private func hint(_ text: String, symbol: String, done: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
            Text(text)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            Button("Fertig", action: done)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.accent, in: Capsule())
        .shadow(color: Theme.accent.opacity(0.4), radius: 12, y: 4)
    }

    private var imageHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.draw")
            Text("Ziehen, mit zwei Fingern zoomen/drehen, lange drücken für mehr · daneben tippen zum Beenden")
                .lineLimit(2)
                .font(.subheadline.weight(.medium))
            Button("Fertig") { model.toggleImageEditMode() }
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.accent, in: Capsule())
        .shadow(color: Theme.accent.opacity(0.4), radius: 12, y: 4)
    }

    private var aiHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.and.scribble")
                .symbolEffect(.pulse)
            Text("Kreise eine Aufgabe mit dem Pencil oder Finger ein")
                .font(.subheadline.weight(.medium))
            Button("Fertig") { model.toggleAIMode() }
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.aiGradient, in: Capsule())
        .shadow(color: Theme.aiColors[1].opacity(0.4), radius: 12, y: 4)
    }
}

struct WorksheetRequest: Identifiable {
    let id = UUID()
    var solutions: String?
    /// Die Seite ist eine gerade eingefügte Buchseite.
    var fromBook = false
    /// Eingekreiste Aufgabe auf der Seite (Anteile 0…1).
    var taskArea: CGRect? = nil
    /// Der eingekreiste Ausschnitt als Bild (zum Lösen, wenn noch keine Lösungen da sind).
    var taskImage: UIImage? = nil
}

/// Herkunft einer Aufgabe, um die Antwort an der richtigen Stelle einzutragen.
struct WorksheetSource {
    var bookPage: UIImage?
    var pageID: UUID?
    var area: CGRect?
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Seitenübersicht

struct PageOverviewView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], spacing: 22) {
                    ForEach(Array((model.notebook?.pages ?? []).enumerated()), id: \.element.id) { index, page in
                        Button {
                            model.goTo(index)
                            dismiss()
                        } label: {
                            VStack(spacing: 6) {
                                PageThumbnail(model: model, page: page)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(index == model.pageIndex ? Theme.accent : .clear, lineWidth: 3)
                                    )
                                Text("Seite \(index + 1)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(PressableStyle())
                        .contextMenu {
                            Button { model.duplicatePage(at: index) } label: {
                                Label("Duplizieren", systemImage: "plus.square.on.square")
                            }
                            Button { model.rotatePage(at: index, clockwise: false) } label: {
                                Label("Nach links drehen", systemImage: "rotate.left")
                            }
                            Button { model.rotatePage(at: index, clockwise: true) } label: {
                                Label("Nach rechts drehen", systemImage: "rotate.right")
                            }
                            Button { model.movePage(from: index, by: -1) } label: {
                                Label("Nach vorne", systemImage: "arrow.left")
                            }
                            .disabled(index == 0)
                            Button { model.movePage(from: index, by: 1) } label: {
                                Label("Nach hinten", systemImage: "arrow.right")
                            }
                            .disabled(index >= (model.notebook?.pages.count ?? 1) - 1)
                            Divider()
                            Button(role: .destructive) { model.deletePage(at: index) } label: {
                                Label("Löschen", systemImage: "trash")
                            }
                            .disabled((model.notebook?.pages.count ?? 0) < 2)
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Seiten")
            .safeAreaInset(edge: .bottom) {
                Text("Lange drücken zum Duplizieren, Drehen, Verschieben oder Löschen")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
    }
}

struct PageThumbnail: View {
    @ObservedObject var model: EditorModel
    let page: Page
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .aspectRatio(CGFloat(page.width / page.height), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .task(id: page) {
            model.flush()
            let store = model.store
            let nbID = model.notebookID
            image = PageRenderer.render(page: page, drawing: store.loadDrawing(notebook: nbID, page: page.id),
                                        image: { store.image($0, notebook: nbID) },
                                        scale: 300 / CGFloat(page.width))
        }
    }
}
