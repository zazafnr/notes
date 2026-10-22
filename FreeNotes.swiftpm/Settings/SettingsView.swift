import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AISettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Bei Fehlern einen anderen Anbieter nehmen", isOn: $settings.autoFallback)
                    Picker("Klassenstufe", selection: $settings.grade) {
                        ForEach(AISettings.grades, id: \.self) { Text($0).tag($0) }
                    }
                } header: {
                    Text("KI")
                } footer: {
                    Text("Welchen Anbieter die App benutzt, wählst du unten beim jeweiligen Anbieter (»Diesen Anbieter verwenden«) oder direkt im KI-Fenster (⋯). Ist »Bei Fehlern …« an und er antwortet nicht (Limit, kein Netz), springt ein anderer mit Key ein.")
                }

                Section {
                    HStack {
                        Text("Claude diesen Monat")
                        Spacer()
                        Text(AISettings.dollar(settings.claudeSpentThisMonth))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Button("Zähler auf 0 setzen", role: .destructive) { settings.resetClaudeUsage() }
                } header: {
                    Text("Claude-Verbrauch")
                } footer: {
                    Text("Geschätzt aus den gemeldeten Tokens, ohne Limit. Alle 0,50 $ erscheint ein kurzer Hinweis. Den genauen Betrag zeigt console.anthropic.com (dort oft mit etwas Verzögerung).")
                }

                ForEach(AIProviderKind.allCases) { provider in
                    ProviderSection(provider: provider)
                }

                Section {
                    NavigationLink {
                        HandwritingSettingsView()
                    } label: {
                        Label("Meine Handschrift", systemImage: "pencil.and.scribble")
                    }
                } header: {
                    Text("Handschrift")
                } footer: {
                    Text("So schreibt die App KI-Antworten in deiner Schrift ins Heft. Hier kannst du Größe und Tempo einstellen und einzelne Buchstaben selbst nachschreiben.")
                }

                Section {
                    Toggle("Auch mit dem Finger zeichnen", isOn: $settings.fingerDrawing)
                    Picker("Doppeltippen / Drücken", selection: $settings.pencilAction) {
                        ForEach(PencilAction.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Blättern", selection: $settings.flipDirection) {
                        ForEach(FlipDirection.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Apple Pencil & Seiten")
                } footer: {
                    Text("Doppeltippen (Pencil 2) oder Drücken (Pencil Pro) löst die gewählte Aktion aus. Blättern: mit einem Finger seitlich wischen oder über das Seitenende hinaus ziehen.")
                }

                BackupSection()

                Section {
                    Button("Einführung erneut zeigen") {
                        settings.hasOnboarded = false
                        dismiss()
                    }
                } footer: {
                    Text("FreeNotes 1.0 · Deine Notizen bleiben auf dem iPad. Nur eingekreiste Ausschnitte und Chat-Nachrichten gehen an den gewählten KI-Anbieter.")
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
    }
}

struct ProviderSection: View {
    @EnvironmentObject private var settings: AISettings
    let provider: AIProviderKind

    @State private var key = ""
    @State private var models: [String] = []
    @State private var loading = false
    @State private var testResult: String?
    @State private var testOK = false

    var body: some View {
        Section {
            Button {
                settings.provider = provider
                Haptics.tap()
            } label: {
                HStack {
                    Label(settings.provider == provider ? "Wird verwendet" : "Diesen Anbieter verwenden",
                          systemImage: settings.provider == provider ? "checkmark.circle.fill" : "circle")
                    Spacer()
                }
            }
            .disabled(settings.provider == provider)
            SecureField("API-Key einfügen", text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: key) { _, value in settings.setKey(value, for: provider) }
            Link(destination: provider.keyHelpURL) {
                Label("Kostenlosen Key holen", systemImage: "arrow.up.right.square")
            }
            HStack {
                TextField("Modell", text: Binding(get: { settings.model(for: provider) },
                                                  set: { settings.setModel($0, for: provider) }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Menu {
                    if provider == .claude {
                        ForEach(ClaudePricing.models) { m in
                            Button(m.title) { settings.setModel(m.id, for: provider) }
                        }
                        Divider()
                    }
                    Button("Standard: \(provider.defaultModel)") { settings.setModel(provider.defaultModel, for: provider) }
                    if !models.isEmpty {
                        Divider()
                        ForEach(models, id: \.self) { m in
                            Button(m) { settings.setModel(m, for: provider) }
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet.circle").font(.title3)
                }
                Button {
                    Task { await loadModels() }
                } label: {
                    if loading { ProgressView() } else { Image(systemName: "arrow.clockwise.circle").font(.title3) }
                }
                .buttonStyle(.borderless)
                .disabled(key.isEmpty || loading)
            }
            Button {
                Task { await test() }
            } label: {
                Label("Verbindung testen", systemImage: "bolt.horizontal.circle")
            }
            .disabled(key.isEmpty || loading)
            if let testResult {
                Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.footnote)
                    .foregroundStyle(testOK ? .green : .red)
            }
        } header: {
            HStack {
                Text(provider.title)
                if settings.provider == provider {
                    Text("AKTIV").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.15), in: Capsule()).foregroundStyle(Theme.accent)
                }
            }
        } footer: {
            Text(provider.limitHint)
        }
        .onAppear { key = settings.key(for: provider) }
    }

    private func loadModels() async {
        loading = true
        defer { loading = false }
        do {
            models = try await AIClient.fetchModels(config: settings.config(for: provider))
            testOK = true
            testResult = "\(models.count) Modelle gefunden. Tippe auf die Liste, um eins zu wählen."
        } catch {
            testOK = false
            testResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func test() async {
        loading = true
        defer { loading = false }
        do {
            let config = try settings.config(for: provider)
            var text = ""
            for try await chunk in AIClient.stream(messages: [AIMessage(role: "user", text: "Antworte nur mit: Hallo! 👋")],
                                                   config: config, effort: "low") {
                switch chunk {
                case .text(let piece): text += piece
                case .usage(let input, let output):
                    settings.recordClaudeUsage(model: config.model, inputTokens: input, outputTokens: output)
                }
            }
            testOK = !text.trimmed.isEmpty
            testResult = testOK ? "Funktioniert: »\(text.trimmed.prefix(60))«" : "Leere Antwort erhalten."
        } catch {
            testOK = false
            testResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
