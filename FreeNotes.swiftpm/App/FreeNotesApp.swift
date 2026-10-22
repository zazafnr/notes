import SwiftUI

@main
struct FreeNotesApp: App {
    @StateObject private var store = LibraryStore()
    @StateObject private var settings = AISettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(settings)
                .tint(Theme.accent)
        }
    }
}

/// Zeigt sofort einen Startbildschirm und baut die Bibliothek erst nach dem ersten Bild auf.
/// Behebt, dass Swift Playgrounds beim ersten Start manchmal schwarz bleibt: Das Fenster hat
/// so von Anfang an Inhalt, und der Wechsel danach erzwingt ein frisches Zeichnen.
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var ready = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            if ready {
                LibraryView()
                    .transition(.opacity)
            } else {
                SplashView()
                    .transition(.opacity)
            }
        }
        .task {
            // Erst ein Bild zeigen, dann die eigentliche Oberfläche
            await Task.yield()
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation(.easeOut(duration: 0.25)) { ready = true }
        }
        .onChange(of: scenePhase) { _, phase in
            // Falls das Fenster beim Start noch nicht aktiv war: beim Aktivwerden neu aufbauen
            if phase == .active, !ready {
                withAnimation(.easeOut(duration: 0.25)) { ready = true }
            }
        }
    }
}

struct SplashView: View {
    @State private var appear = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Theme.aiGradient)
                    .frame(width: 96, height: 96)
                    .shadow(color: Theme.aiColors[1].opacity(0.35), radius: 18, y: 8)
                Image(systemName: "pencil.and.scribble")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(appear ? 1 : 0.85)
            .opacity(appear ? 1 : 0)
            Text("FreeNotes")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .opacity(appear ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { appear = true }
        }
    }
}
