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
    @State private var showScanner = false
    @State private var showCamera = false
    @State private var showImporter = false
    @State private var showPages = false
    @State private var confirmDelete = false
    @State private var shareURL: ShareItem?

    init(notebookID: UUID, store: LibraryStore, settings: AISettings) {
        _model = StateObject(wrappedValue: EditorModel(notebookID: notebookID, store: store))
        let nb = store.notebook(notebookID)
        let threadID = store.threadID(forNotebook: notebookID, title: nb?.title ?? "Heft")
        _chat = StateObject(wrappedValue: ChatController(store: store, settings: settings, threadID: threadID,
                                                         subject: store.subject(nb?.subjectID)?.name))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: .secondarySystemBackground).ignoresSafeArea()

            if let page = model.currentPage {
                PageCanvas(model: model, store: store, page: page, fingerDrawing: settings.fingerDrawing,
                           flipDirection: settings.flipDirection, pencilAction: settings.pencilAction)
                    .id(page.id)
                    .ignoresSafeArea(edges: .bottom)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
            }

            VStack(spacing: 10) {
                topBar
                if model.aiMode {
                    aiHint.transition(.move(edge: .top).combined(with: .opacity))
                }
                if model.imageEditMode {
                    imageHint.transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
        }
        .overlay(alignment: .trailing) {
            if model.showPanel {
                AIPanelView(chat: chat, title: model.notebook?.title ?? "KI",
                            onClose: { model.showPanel = false },
                            onInsert: { model.insertAnswer($0) },
                            pageImage: { model.currentPageImage() })
                    .frame(width: 420)
                    .glass(cornerRadius: 26)
                    .padding(.trailing, 12)
                    .padding(.top, 70)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: model.showPanel)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.aiMode)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.imageEditMode)
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
            AskSheet(snapshot: snap) { display, prompt in
                chat.send(display: display, prompt: prompt, images: [snap.image])
                model.aiMode = false
                model.showPanel = true
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    model.addImage(img)
                }
                photoItem = nil
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

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Button {
                    model.close()
                    dismiss()
                } label: { ToolbarIcon(symbol: "chevron.left") }

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
                .padding(.trailing, 10)
            }
            .padding(4)
            .glass(cornerRadius: 24)

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                Button { model.undo() } label: { ToolbarIcon(symbol: "arrow.uturn.backward") }
                Button { model.redo() } label: { ToolbarIcon(symbol: "arrow.uturn.forward") }
            }
            .padding(4)
            .glass(cornerRadius: 24)

            pageControls

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

                Menu {
                    Button {
                        if let url = model.exportPDF() { shareURL = ShareItem(url: url) }
                    } label: { Label("Als PDF teilen", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Seite löschen", systemImage: "trash")
                    }
                    .disabled((model.notebook?.pages.count ?? 0) < 2)
                    Button { model.toggleImageEditMode() } label: {
                        Label(model.imageEditMode ? "Bilder fertig bearbeitet" : "Bilder verschieben & skalieren",
                              systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    }
                    .disabled(model.currentPage?.items.isEmpty ?? true)
                } label: { ToolbarIcon(symbol: "ellipsis.circle") }
            }
            .padding(4)
            .glass(cornerRadius: 24)
        }
        .buttonStyle(PressableStyle())
    }

    private var pageControls: some View {
        let count = model.notebook?.pages.count ?? 0
        return HStack(spacing: 2) {
            Button { model.goTo(model.pageIndex - 1) } label: { ToolbarIcon(symbol: "chevron.up") }
                .disabled(model.pageIndex == 0)
            Button { showPages = true } label: {
                Text("\(model.pageIndex + 1) / \(count)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .contentTransition(.numericText())
                    .frame(minWidth: 52, minHeight: 40)
            }
            Button { model.goTo(model.pageIndex + 1) } label: { ToolbarIcon(symbol: "chevron.down") }
                .disabled(model.pageIndex >= count - 1)
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
            Button { showPhotos = true } label: { Label("Foto oder Screenshot", systemImage: "photo.on.rectangle") }
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

    private var imageHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.draw")
            Text("Bilder ziehen, am Punkt unten rechts skalieren")
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
                Text("Lange drücken zum Duplizieren, Verschieben oder Löschen")
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
