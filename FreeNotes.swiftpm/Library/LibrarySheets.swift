import SwiftUI

struct NewNotebookSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var preselectedSubject: UUID?
    var onCreate: (Notebook) -> Void

    @State private var title = ""
    @State private var subjectID: UUID?
    @State private var colorIndex = 0
    @State private var paper: PaperStyle = .lined

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titel, z. B. »Mathe Klassenarbeit«", text: $title)
                        .font(.title3)
                }
                Section("Fach") {
                    Picker("Fach", selection: $subjectID) {
                        Text("Kein Fach").tag(UUID?.none)
                        ForEach(store.subjects) { s in
                            Label(s.name, systemImage: s.symbol).tag(UUID?.some(s.id))
                        }
                    }
                    .onChange(of: subjectID) { _, id in
                        if let s = store.subject(id) { withAnimation { colorIndex = s.colorIndex } }
                    }
                }
                Section("Farbe") {
                    ColorRow(selection: $colorIndex)
                }
                Section("Papier") {
                    HStack(spacing: 14) {
                        ForEach(PaperStyle.allCases) { style in
                            PaperTile(style: style, selected: paper == style)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.3)) { paper = style }
                                    Haptics.tap()
                                }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("Neues Heft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Erstellen") {
                        let nb = store.createNotebook(title: title, subjectID: subjectID, colorIndex: colorIndex, paper: paper)
                        Haptics.success()
                        onCreate(nb)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                subjectID = preselectedSubject
                if let s = store.subject(preselectedSubject) { colorIndex = s.colorIndex }
            }
        }
    }
}

struct ColorRow: View {
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Theme.subjectColors.indices, id: \.self) { i in
                Circle()
                    .fill(Theme.color(i).gradient)
                    .frame(width: 32, height: 32)
                    .overlay {
                        if selection == i {
                            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .scaleEffect(selection == i ? 1.12 : 1)
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { selection = i }
                        Haptics.tap()
                    }
            }
        }
        .padding(.vertical, 4)
    }
}

struct PaperTile: View {
    let style: PaperStyle
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                var path = Path()
                switch style {
                case .blank: break
                case .lined:
                    var y: CGFloat = 14
                    while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += 8 }
                case .grid:
                    var x: CGFloat = 6
                    while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += 6 }
                    var y: CGFloat = 6
                    while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += 6 }
                case .dotted:
                    var y: CGFloat = 7
                    while y < size.height {
                        var x: CGFloat = 7
                        while x < size.width { path.addEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)); x += 7 }
                        y += 7
                    }
                }
                if style == .dotted {
                    ctx.fill(path, with: .color(.gray.opacity(0.6)))
                } else {
                    ctx.stroke(path, with: .color(.blue.opacity(0.25)), lineWidth: 0.6)
                }
            }
            .frame(width: 60, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Theme.accent : Color.gray.opacity(0.3), lineWidth: selected ? 2.5 : 1))
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            .scaleEffect(selected ? 1.05 : 1)
            Text(style.title).font(.caption).foregroundStyle(selected ? Theme.accent : .secondary)
        }
    }
}

struct SubjectEditorSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let subject: Subject?

    @State private var name = ""
    @State private var colorIndex = 0
    @State private var symbol = "folder"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: symbol)
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Theme.color(colorIndex).gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentTransition(.symbolEffect(.replace))
                        TextField("Name des Fachs", text: $name).font(.title3)
                    }
                }
                Section("Farbe") { ColorRow(selection: $colorIndex) }
                Section("Symbol") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
                        ForEach(Theme.subjectSymbols, id: \.self) { s in
                            Image(systemName: s)
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .foregroundStyle(symbol == s ? .white : .primary)
                                .background(symbol == s ? AnyShapeStyle(Theme.color(colorIndex)) : AnyShapeStyle(Color.primary.opacity(0.06)),
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.3)) { symbol = s }
                                    Haptics.tap()
                                }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle(subject == nil ? "Neues Fach" : "Fach bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        let trimmed = name.trimmed
                        if var s = subject {
                            s.name = trimmed
                            s.colorIndex = colorIndex
                            s.symbol = symbol
                            store.updateSubject(s)
                        } else {
                            store.addSubject(Subject(name: trimmed, colorIndex: colorIndex, symbol: symbol))
                        }
                        dismiss()
                    }
                    .disabled(name.trimmed.isEmpty)
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                if let s = subject {
                    name = s.name
                    colorIndex = s.colorIndex
                    symbol = s.symbol
                } else {
                    colorIndex = store.subjects.count % Theme.subjectColors.count
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Allgemeiner KI-Chat

struct GeneralChatView: View {
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var chat: ChatController

    init(store: LibraryStore, settings: AISettings) {
        _chat = StateObject(wrappedValue: ChatController(store: store, settings: settings,
                                                         threadID: store.latestGeneralThreadID()))
    }

    var body: some View {
        AIPanelView(chat: chat, title: chat.thread?.title ?? "KI-Chat")
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("KI-Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            chat.threadID = store.newGeneralThread()
                        } label: { Label("Neuer Chat", systemImage: "square.and.pencil") }
                        let others = store.generalThreads.filter { !$0.messages.isEmpty }
                        if !others.isEmpty {
                            Section("Frühere Chats") {
                                ForEach(others) { t in
                                    Button(t.title) { chat.threadID = t.id }
                                }
                            }
                        }
                    } label: {
                        Label("Chats", systemImage: "square.and.pencil")
                    }
                }
            }
    }
}
