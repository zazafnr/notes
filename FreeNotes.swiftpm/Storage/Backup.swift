import SwiftUI
import UniformTypeIdentifiers

/// Sicherung aller Hefte als ZIP (über die Dateien-App) und Wiederherstellen aus dem entpackten Ordner.
enum Backup {
    /// Packt den ganzen FreeNotes-Ordner in eine ZIP-Datei (das System erledigt das Packen).
    @MainActor
    static func makeArchive(store: LibraryStore) -> URL? {
        store.saveNow()
        var result: URL?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: store.root, options: .forUploading, error: &coordinatorError) { zipURL in
            let stamp = Date().formatted(.iso8601.year().month().day())
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("FreeNotes-Sicherung-\(stamp).zip")
            try? FileManager.default.removeItem(at: target)
            if (try? FileManager.default.copyItem(at: zipURL, to: target)) != nil { result = target }
        }
        return coordinatorError == nil ? result : nil
    }

    enum RestoreError: LocalizedError {
        case notABackup, copyFailed

        var errorDescription: String? {
            switch self {
            case .notABackup:
                return "In diesem Ordner ist keine FreeNotes-Sicherung. Tippe in der Dateien-App zuerst auf die ZIP-Datei, damit sie entpackt wird, und wähle dann den entpackten Ordner »FreeNotes«."
            case .copyFailed:
                return "Die Sicherung konnte nicht kopiert werden."
            }
        }
    }

    /// Ersetzt die aktuellen Daten durch einen entpackten Sicherungsordner.
    @MainActor
    static func restore(from folder: URL, into store: LibraryStore) throws {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        // Gewählt werden kann der Ordner »FreeNotes« selbst oder der Ordner darüber.
        let candidates = [folder, folder.appendingPathComponent("FreeNotes", isDirectory: true)]
        guard let source = candidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("library.json").path) }) else {
            throw RestoreError.notABackup
        }
        let staging = fm.temporaryDirectory.appendingPathComponent("FreeNotes-Restore-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: source, to: staging)
            if fm.fileExists(atPath: store.root.path) {
                _ = try fm.replaceItemAt(store.root, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: store.root)
            }
        } catch {
            throw RestoreError.copyFailed
        }
        store.reload()
    }
}

struct BackupSection: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var archive: ShareItem?
    @State private var showImporter = false
    @State private var confirmRestore: URL?
    @State private var message: String?

    var body: some View {
        Section {
            Button {
                if let url = Backup.makeArchive(store: store) {
                    archive = ShareItem(url: url)
                } else {
                    message = "Die Sicherung konnte nicht erstellt werden."
                }
            } label: {
                Label("Sicherung erstellen", systemImage: "externaldrive.badge.checkmark")
            }
            Button {
                showImporter = true
            } label: {
                Label("Sicherung wiederherstellen …", systemImage: "arrow.counterclockwise.circle")
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Sicherung")
        } footer: {
            Text("Vor einem Update: »Sicherung erstellen« → »In Dateien sichern«. Nach dem Update: ZIP in der Dateien-App antippen (wird entpackt), dann »Sicherung wiederherstellen« und den Ordner »FreeNotes« wählen. Deine Hefte, Bilder und Chats sind dann wieder da.")
        }
        .sheet(item: $archive) { item in
            ShareSheet(items: [item.url])
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { confirmRestore = url }
        }
        .confirmationDialog("Aktuelle Hefte durch die Sicherung ersetzen?",
                            isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }),
                            titleVisibility: .visible) {
            Button("Wiederherstellen", role: .destructive) {
                guard let url = confirmRestore else { return }
                do {
                    try Backup.restore(from: url, into: store)
                    message = "Sicherung wiederhergestellt: \(store.notebooks.count) Hefte."
                    Haptics.success()
                } catch {
                    message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    Haptics.error()
                }
                confirmRestore = nil
            }
        } message: {
            Text("Alles, was jetzt in der App ist, wird durch die Sicherung ersetzt.")
        }
    }
}
