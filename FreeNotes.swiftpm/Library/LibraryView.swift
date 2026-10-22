import SwiftUI

enum SidebarItem: Hashable {
    case all, favorites, recent, subject(UUID), chat
}

struct OpenNotebook: Identifiable {
    let id: UUID
}

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AISettings

    @State private var selection: SidebarItem? = .all
    @State private var openNotebook: OpenNotebook?
    @State private var showNewNotebook = false
    @State private var subjectSheet: SubjectSheetItem?
    @State private var showSettings = false
    @State private var showOnboarding = false
    @State private var pendingOpen: UUID?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            switch selection ?? .all {
            case .chat:
                GeneralChatView(store: store, settings: settings)
            case let item:
                NotebookGridView(filter: item,
                                 onOpen: { openNotebook = OpenNotebook(id: $0) },
                                 onNew: { showNewNotebook = true })
            }
        }
        .fullScreenCover(item: $openNotebook) { item in
            NotebookEditorView(notebookID: item.id, store: store, settings: settings)
                .environmentObject(store)
                .environmentObject(settings)
        }
        .sheet(isPresented: $showNewNotebook, onDismiss: {
            if let id = pendingOpen {
                pendingOpen = nil
                openNotebook = OpenNotebook(id: id)
            }
        }) {
            NewNotebookSheet(preselectedSubject: currentSubjectID) { nb in
                pendingOpen = nb.id
            }
            .environmentObject(store)
        }
        .sheet(item: $subjectSheet) { item in
            SubjectEditorSheet(subject: item.subject).environmentObject(store)
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            if !settings.hasOnboarded { showOnboarding = true }
        }) {
            SettingsView().environmentObject(settings)
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView().environmentObject(settings)
                .interactiveDismissDisabled()
        }
        .onAppear {
            if !settings.hasOnboarded { showOnboarding = true }
        }
    }

    private var currentSubjectID: UUID? {
        if case .subject(let id) = selection { return id }
        return nil
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("Alle Hefte", systemImage: "books.vertical").tag(SidebarItem.all)
                Label("Favoriten", systemImage: "star").tag(SidebarItem.favorites)
                Label("Zuletzt geöffnet", systemImage: "clock").tag(SidebarItem.recent)
            }
            Section("Fächer") {
                ForEach(store.subjects) { subject in
                    Label {
                        HStack {
                            Text(subject.name)
                            Spacer()
                            Text("\(store.notebooks.filter { $0.subjectID == subject.id }.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: subject.symbol)
                            .foregroundStyle(Theme.color(subject.colorIndex))
                    }
                    .tag(SidebarItem.subject(subject.id))
                    .contextMenu {
                        Button { subjectSheet = SubjectSheetItem(subject: subject) } label: {
                            Label("Bearbeiten", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            if selection == .subject(subject.id) { selection = .all }
                            store.deleteSubject(subject.id)
                        } label: { Label("Fach löschen", systemImage: "trash") }
                    }
                }
                Button { subjectSheet = SubjectSheetItem(subject: nil) } label: {
                    Label("Fach hinzufügen", systemImage: "plus.circle")
                }
                .foregroundStyle(Theme.accent)
            }
            Section("KI") {
                Label {
                    Text("KI-Chat")
                } icon: {
                    Image(systemName: "sparkles").foregroundStyle(Theme.aiGradient)
                }
                .tag(SidebarItem.chat)
            }
        }
        .navigationTitle("FreeNotes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
    }
}

struct SubjectSheetItem: Identifiable {
    let id = UUID()
    let subject: Subject?
}

// MARK: - Raster mit Heften

struct NotebookGridView: View {
    @EnvironmentObject private var store: LibraryStore
    let filter: SidebarItem
    var onOpen: (UUID) -> Void
    var onNew: () -> Void

    @State private var search = ""
    @State private var renaming: Notebook?
    @State private var newTitle = ""
    @State private var deleting: Notebook?

    private var title: String {
        switch filter {
        case .all, .chat: return "Alle Hefte"
        case .favorites: return "Favoriten"
        case .recent: return "Zuletzt geöffnet"
        case .subject(let id): return store.subject(id)?.name ?? "Fach"
        }
    }

    private var notebooks: [Notebook] {
        var list: [Notebook]
        switch filter {
        case .all, .chat: list = store.notebooks.sorted { $0.modified > $1.modified }
        case .favorites: list = store.notebooks.filter(\.isFavorite).sorted { $0.modified > $1.modified }
        case .recent: list = store.notebooks.filter { $0.opened != nil }.sorted { ($0.opened ?? .distantPast) > ($1.opened ?? .distantPast) }
        case .subject(let id): list = store.notebooks.filter { $0.subjectID == id }.sorted { $0.modified > $1.modified }
        }
        let q = search.trimmed
        if !q.isEmpty { list = list.filter { $0.title.localizedCaseInsensitiveContains(q) } }
        return list
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 28)], spacing: 32) {
                NewNotebookTile(action: onNew)
                ForEach(notebooks) { nb in
                    Button { onOpen(nb.id) } label: {
                        NotebookCoverView(notebook: nb, subject: store.subject(nb.subjectID),
                                          thumb: store.thumbnail(notebook: nb.id), version: store.thumbVersion)
                    }
                    .buttonStyle(PressableStyle())
                    .hoverEffect(.lift)
                    .scrollTransition(.animated(.spring)) { content, phase in
                        content
                            .opacity(phase.isIdentity ? 1 : 0.3)
                            .scaleEffect(phase.isIdentity ? 1 : 0.92)
                    }
                    .contextMenu { menu(for: nb) }
                }
            }
            .padding(28)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: notebooks.map(\.id))

            if notebooks.isEmpty {
                ContentUnavailableView(search.isEmpty ? "Noch keine Hefte" : "Nichts gefunden",
                                       systemImage: search.isEmpty ? "book.closed" : "magnifyingglass",
                                       description: Text(search.isEmpty ? "Tippe auf »Neues Heft«, um loszulegen." : "Versuch einen anderen Suchbegriff."))
                    .padding(.top, 40)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(title)
        .searchable(text: $search, prompt: "Hefte durchsuchen")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onNew) { Label("Neues Heft", systemImage: "plus") }
            }
        }
        .alert("Heft umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Titel", text: $newTitle)
            Button("Abbrechen", role: .cancel) { renaming = nil }
            Button("Sichern") {
                if let nb = renaming, !newTitle.trimmed.isEmpty {
                    store.updateNotebook(nb.id) { $0.title = newTitle.trimmed }
                }
                renaming = nil
            }
        }
        .confirmationDialog("Heft wirklich löschen?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                if let nb = deleting { withAnimation { store.deleteNotebook(nb.id) } }
                deleting = nil
            }
        } message: {
            Text("Alle Seiten und der KI-Verlauf werden gelöscht.")
        }
    }

    @ViewBuilder
    private func menu(for nb: Notebook) -> some View {
        Button {
            store.updateNotebook(nb.id) { $0.isFavorite.toggle() }
        } label: {
            Label(nb.isFavorite ? "Kein Favorit mehr" : "Favorit", systemImage: nb.isFavorite ? "star.slash" : "star")
        }
        Button {
            newTitle = nb.title
            renaming = nb
        } label: { Label("Umbenennen", systemImage: "pencil") }
        Menu {
            Button("Kein Fach") { store.updateNotebook(nb.id) { $0.subjectID = nil } }
            ForEach(store.subjects) { s in
                Button(s.name) { store.updateNotebook(nb.id) { $0.subjectID = s.id } }
            }
        } label: { Label("Fach ändern", systemImage: "folder") }
        Divider()
        Button(role: .destructive) { deleting = nb } label: { Label("Löschen", systemImage: "trash") }
    }
}

struct NewNotebookTile: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(Theme.accent.opacity(0.5))
                    .background(Theme.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 30, weight: .semibold))
                            Text("Neues Heft").font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .aspectRatio(0.74, contentMode: .fit)
                Text(" ").font(.headline)
                Text(" ").font(.caption)
            }
        }
        .buttonStyle(PressableStyle())
        .hoverEffect(.lift)
    }
}

struct NotebookCoverView: View {
    let notebook: Notebook
    let subject: Subject?
    let thumb: UIImage?
    let version: Int

    private var color: Color { Theme.color(notebook.colorIndex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(color.gradient)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.black.opacity(0.14)).frame(width: 12)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                if let thumb {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                        .padding(EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 12))
                } else {
                    VStack {
                        Spacer()
                        Image(systemName: subject?.symbol ?? "book.closed")
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 12)
                }

                if notebook.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.yellow)
                        .padding(7)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(8)
                }
            }
            .aspectRatio(0.74, contentMode: .fit)
            .shadow(color: color.opacity(0.35), radius: 12, y: 8)

            Text(notebook.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            HStack(spacing: 4) {
                if let subject {
                    Circle().fill(Theme.color(subject.colorIndex)).frame(width: 7, height: 7)
                    Text(subject.name)
                    Text("·")
                }
                Text("\(notebook.pages.count) \(notebook.pages.count == 1 ? "Seite" : "Seiten")")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}
