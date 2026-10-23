import SwiftUI

/// Was in Handschrift ins Heft soll (aus dem KI-Chat oder selbst eingetippt).
struct WriteRequest: Identifiable {
    let id = UUID()
    /// KI-Antwort (leer = selbst tippen).
    var answer: String
    var question: String?
    var images: [UIImage] = []
    /// Die Aufgabe stammt von einem Zettel/einer Buchseite: Antwort kann direkt dort eingetragen werden.
    var canFillWorksheet = false
    /// Zettel-Eintrag als Vorauswahl (Seite ist ein Arbeitsblatt bzw. Bild).
    var prefersWorksheet = false
    var worksheetSource: WorksheetSource?
}

/// Ziel im Schreib-Fenster.
enum WriteTarget: Hashable {
    case below, newPage, worksheet
}

/// Vorschau und Bestätigung: Die KI formt die Antwort wie einen Heft-Eintrag, dann wird geschrieben.
struct HandwritingWriteSheet: View {
    @ObservedObject var model: EditorModel
    let request: WriteRequest
    /// Stattdessen auf dem Zettel an der richtigen Stelle eintragen.
    var onWorksheet: (() -> Void)? = nil
    @EnvironmentObject private var settings: AISettings
    @ObservedObject private var hw = HandwritingStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var formatting = false
    @State private var error: String?
    @State private var target: WriteTarget = .below
    @State private var header = false
    @State private var useAI = true
    @State private var formatTask: Task<Void, Never>?
    @State private var preview: UIImage?
    @FocusState private var editing: Bool

    private var hasAnswer: Bool { !request.answer.trimmed.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    placementOptions
                    if target == .worksheet {
                        worksheetInfo
                    } else {
                        previewCard
                        if hasAnswer { aiOptions }
                        editor
                    }
                    speedOptions
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("In Handschrift ins Heft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        formatTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let content = text
                        let chosen = target
                        formatTask?.cancel()
                        dismiss()
                        if chosen == .worksheet {
                            onWorksheet?()
                            return
                        }
                        // Erst nach dem Schließen schreiben, damit man zusieht
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 450_000_000)
                            model.writeHandwriting(content, placement: chosen == .newPage ? .newPage : .below)
                        }
                    } label: {
                        Label("Schreiben", systemImage: "pencil.and.scribble").font(.headline)
                    }
                    .disabled(target != .worksheet && (text.trimmed.isEmpty || formatting))
                }
            }
        }
        .onAppear(perform: setup)
        .onChange(of: target) { _, newTarget in
            if newTarget != .worksheet, hasAnswer, text.isEmpty, !formatting { format() }
        }
        .onDisappear { formatTask?.cancel() }
    }

    // MARK: Teile

    private var previewCard: some View {
        ZStack {
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            } else {
                Color.white.frame(height: 220)
            }
            if formatting {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("KI schreibt es wie ins Heft …").font(.subheadline.weight(.medium))
                }
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .animation(.easeInOut(duration: 0.25), value: preview)
        .task(id: "\(text)|\(hw.size)|\(hw.messiness)") {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            renderPreview()
        }
    }

    private var aiOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $useAI) {
                Label("Wie ein Schüler ins Heft schreiben (KI formatiert)", systemImage: "sparkles")
            }
            .onChange(of: useAI) { _, _ in format() }
            if useAI {
                Toggle(isOn: $header) {
                    Label("Kopfzeile »S. … Nr. …«", systemImage: "textformat")
                }
                .onChange(of: header) { _, _ in format() }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Text").font(.headline)
            TextEditor(text: $text)
                .font(.system(.body, design: .rounded))
                .frame(minHeight: 160)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .focused($editing)
            Text("__Text__ wird unterstrichen, ==Ergebnis== doppelt unterstrichen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var placementOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wohin").font(.headline)
            Picker("Wohin", selection: $target) {
                if request.canFillWorksheet {
                    Text("Auf dem Zettel").tag(WriteTarget.worksheet)
                }
                if model.canWriteBelow {
                    Text("Unter das Geschriebene").tag(WriteTarget.below)
                }
                Text("Neue Seite").tag(WriteTarget.newPage)
            }
            .pickerStyle(.segmented)
            if !model.canWriteBelow, target == .newPage {
                Text("Auf dieser Seite ist kein freier Platz unter dem Inhalt – es geht auf einer neuen Seite weiter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var worksheetInfo: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.text.viewfinder")
                .font(.title2)
                .foregroundStyle(Theme.aiGradient)
            VStack(alignment: .leading, spacing: 4) {
                Text("Direkt auf dem Zettel eintragen").font(.headline)
                Text("Die Antwort wird genau an die Stelle der eingekreisten Aufgabe geschrieben – in die Lücken, Linien oder Tabellenfelder, auch über einem Bild. Du siehst die Stellen vorher und kannst alles ändern.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var speedOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tempo").font(.headline)
            Picker("Tempo", selection: $hw.speed) {
                ForEach(HWSpeed.allCases) { s in Text(s.title).tag(s) }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: Ablauf

    private func setup() {
        if request.canFillWorksheet, request.prefersWorksheet {
            target = .worksheet
        } else {
            target = model.canWriteBelow ? .below : .newPage
        }
        header = target != .below || model.currentPageIsEmpty
        if hasAnswer {
            // Für den Zettel formatiert die KI selbst passend zu den Lücken
            if target != .worksheet { format() }
        } else {
            useAI = false
            editing = true
        }
    }

    private func format() {
        formatTask?.cancel()
        error = nil
        guard hasAnswer else { return }
        guard useAI else {
            formatting = false
            text = HandwritingPrompts.cleanNotebookText(request.answer)
            return
        }
        formatting = true
        let system = HandwritingPrompts.notebookSystem(grade: settings.grade)
        let user = HandwritingPrompts.notebookUser(answer: request.answer, question: request.question,
                                                   header: header ? .pageAndNumber(nil) : .none)
        let images = request.images.prefix(2).compactMap { $0.jpegBase64(maxSide: 1400) }
        formatTask = Task {
            do {
                let result = try await AIRequest.text(system: system, user: user, images: images, settings: settings)
                guard !Task.isCancelled else { return }
                text = HandwritingPrompts.cleanNotebookText(result)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "KI nicht erreichbar – die Antwort wird unverändert geschrieben."
                text = HandwritingPrompts.cleanNotebookText(request.answer)
            }
            formatting = false
        }
    }

    private func renderPreview() {
        guard let page = model.currentPage else { return }
        let paper = page.background == nil ? page.paper : .lined
        let sample = text.trimmed.isEmpty ? "Hier erscheint deine Handschrift." : text
        let (layout, xh) = model.previewLayout(sample, paper: paper, size: page.size)
        let bottom = layout.bounds.isNull ? 300 : layout.bounds.maxY + 40
        let size = CGSize(width: page.size.width, height: min(page.size.height, max(260, bottom)))
        preview = HandwritingInk.previewImage(layout, paper: paper, size: size, color: HandwritingInk.color,
                                              xHeight: xh, scale: 1.2)
    }
}

/// Anzeige unten, während geschrieben wird.
struct WritingStatusBar: View {
    @ObservedObject var model: EditorModel
    let status: WritingStatus

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "pencil.and.scribble")
                .font(.system(size: 17, weight: .semibold))
                .symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.pages > 1 ? "Schreibt … Seite \(status.page) von \(status.pages)" : "Schreibt in deiner Handschrift …")
                    .font(.subheadline.weight(.semibold))
                TimelineView(.animation(minimumInterval: 0.1)) { _ in
                    ProgressView(value: model.writingProgress)
                        .tint(.white)
                        .frame(width: 180)
                }
            }
            Button("Überspringen") { model.skipWriting() }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.white.opacity(0.22), in: Capsule())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.aiGradient, in: Capsule())
        .shadow(color: Theme.aiColors[1].opacity(0.4), radius: 14, y: 5)
        .buttonStyle(PressableStyle())
    }
}
