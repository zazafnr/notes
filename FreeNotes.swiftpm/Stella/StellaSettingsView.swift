import SwiftUI

/// Abschnitt in den Einstellungen: Mit Stella verbinden.
struct StellaSection: View {
    @ObservedObject private var stella = StellaSync.shared

    var body: some View {
        Section {
            NavigationLink {
                StellaSettingsView()
            } label: {
                HStack {
                    Label("Stella", systemImage: "sparkles")
                    Spacer()
                    Text(stella.isConnected ? "Verbunden" : "Aus")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Stella")
        } footer: {
            Text("Stella löst deine HÜs auf deinem Server – FreeNotes schreibt sie dann in deiner Handschrift ins passende Fach-Heft.")
        }
    }
}

struct StellaSettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var stella = StellaSync.shared

    @State private var server = ""
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            if stella.isConnected {
                Section {
                    LabeledContent("Server", value: stella.server)
                    LabeledContent("Konto", value: stella.email)
                    if let last = stella.lastSync {
                        LabeledContent("Zuletzt abgeholt", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let lastError = stella.lastError {
                        Text(lastError).font(.footnote).foregroundStyle(.red)
                    }
                    Toggle("Beim Öffnen automatisch abholen", isOn: $stella.autoSync)
                    Button {
                        Task { await stella.sync(store: store, manual: true) }
                    } label: {
                        HStack {
                            Label("Jetzt abholen", systemImage: "arrow.down.circle")
                            if stella.isSyncing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(stella.isSyncing)
                    Button("Trennen", role: .destructive) { stella.disconnect() }
                } header: {
                    Text("Verbunden")
                } footer: {
                    Text("Gelöste HÜs landen im Heft des passenden Fachs (z. B. »Französisch«) – unter dem zuletzt Geschriebenen oder auf einer neuen Seite. Gibt es kein Heft für das Fach, legt FreeNotes eins an.")
                }
            } else {
                Section {
                    TextField("Server, z. B. stella.deinedomain.at", text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("E-Mail", text: $email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    SecureField("Passwort", text: $password)
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Text("Verbinden")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || server.trimmed.isEmpty || email.trimmed.isEmpty || password.isEmpty)
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Mit Stella verbinden")
                } footer: {
                    Text("Gleiche Adresse, E-Mail und Passwort wie in der Stella-App.")
                }
            }
        }
        .navigationTitle("Stella")
        .onAppear {
            server = stella.server
            email = stella.email
        }
    }

    private func connect() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await stella.connect(server: server, email: email, password: password)
            password = ""
            await stella.sync(store: store, manual: true)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
