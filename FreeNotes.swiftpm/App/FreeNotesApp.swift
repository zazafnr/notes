import SwiftUI

@main
struct FreeNotesApp: App {
    @StateObject private var store = LibraryStore()
    @StateObject private var settings = AISettings()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .environmentObject(settings)
                .tint(Theme.accent)
        }
    }
}
