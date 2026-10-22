import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AISettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Anbieter", selection: $settings.provider) {
                        ForEach(AIProviderKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Bei Limit automatisch zum anderen Anbieter wechseln", isOn: $settings.autoFallback)
                    Picker("Klassenstufe", selection: $settings.grade) {
                        ForEach(AISettings.grades, id: \.self) { Text($0).tag($0) }
                    }
                } header: {
                    Text("KI")
                } footer: {
                    Text("Kein Anbieter ist unbegrenzt kostenlos. Beide haben Tageslimits. Mit zwei Keys kann die App bei einem Limit automatisch wechseln.")
                }

                ForEach(AIProviderKind.allCases) { provider in
                    ProviderSection(provider: provider)
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
            for try await chunk in AIClient.stream(messages: [AIMessage(role: "user", text: "Antworte nur mit: Hallo! 👋")], config: config) {
                text += chunk
            }
            testOK = !text.trimmed.isEmpty
            testResult = testOK ? "Funktioniert: »\(text.trimmed.prefix(60))«" : "Leere Antwort erhalten."
        } catch {
            testOK = false
            testResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
