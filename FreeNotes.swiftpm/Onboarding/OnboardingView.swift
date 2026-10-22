import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var settings: AISettings
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    @State private var key = ""
    @State private var openRouterKey = ""
    @State private var glow = false

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $step) {
                welcome.tag(0)
                lassoIntro.tag(1)
                keySetup.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if step < 2 {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { step += 1 }
                } else {
                    finish()
                }
            } label: {
                Text(step < 2 ? "Weiter" : (key.trimmed.isEmpty && openRouterKey.trimmed.isEmpty ? "Später einrichten" : "Los geht's"))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: 360)
                    .padding(.vertical, 16)
                    .background(Theme.aiGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentTransition(.opacity)
            }
            .buttonStyle(PressableStyle())
            .padding(24)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { glow = true }
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(Theme.aiGradient)
                    .frame(width: 150, height: 150)
                    .blur(radius: glow ? 40 : 24)
                    .opacity(0.6)
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(Theme.aiGradient)
                    .frame(width: 120, height: 120)
                    .overlay(Image(systemName: "pencil.and.scribble").font(.system(size: 52, weight: .semibold)).foregroundStyle(.white))
                    .shadow(color: Theme.aiColors[1].opacity(0.5), radius: 20, y: 10)
            }
            Text("Willkommen bei FreeNotes")
                .font(.largeTitle.weight(.bold))
            Text("Mitschreiben mit dem Apple Pencil, Buchseiten scannen, Fächer ordnen und mit KI lernen. Alles in einer App.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding(30)
    }

    private var lassoIntro: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.white)
                    .frame(width: 260, height: 170)
                    .shadow(color: .black.opacity(0.1), radius: 12, y: 6)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Aufgabe 3").font(.caption.weight(.bold)).foregroundStyle(.black.opacity(0.6))
                    Text("2x² − 8 = 0").font(.system(size: 26, weight: .medium, design: .serif)).foregroundStyle(.black)
                }
                Ellipse()
                    .trim(from: 0, to: glow ? 1 : 0.15)
                    .stroke(Theme.aiGradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 210, height: 110)
                    .shadow(color: Theme.aiColors[1].opacity(0.8), radius: 10)
            }
            Text("Einkreisen. Fragen. Verstehen.")
                .font(.largeTitle.weight(.bold))
            Text("Tippe auf ✨ oder doppeltippe auf den Pencil, kreise eine Aufgabe ein und wähle »Lösen«, »Erklären« oder »Nur Tipp«. Die Antwort erscheint direkt neben deiner Seite.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding(30)
    }

    private var keySetup: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(Theme.aiGradient)
                    .symbolEffect(.bounce, value: step)
                Text("KI einrichten")
                    .font(.largeTitle.weight(.bold))
                Text("Trag Claude und/oder OpenRouter ein. Welchen Anbieter die App nutzt, stellst du später in den Einstellungen oder direkt im KI-Fenster um.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)

                keyCard(title: "Claude-Key", badge: "ca. 5 $ im Monat",
                        hint: "console.anthropic.com → API Keys → Create Key. Vorher Guthaben aufladen (z. B. 5 $).",
                        provider: .claude, text: $key)
                keyCard(title: "OpenRouter-Key", badge: "kostenlos",
                        hint: "openrouter.ai → Anmelden → Keys → Create Key.",
                        provider: .openrouter, text: $openRouterKey)

                Text("Du kannst auch nur einen der beiden eintragen. Google Gemini gibt es zusätzlich in den Einstellungen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(30)
            .frame(maxWidth: .infinity)
        }
    }

    private func keyCard(title: String, badge: String, hint: String, provider: AIProviderKind, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                    .foregroundStyle(Theme.accent)
                Spacer()
                Link(destination: provider.keyHelpURL) {
                    Label("Öffnen", systemImage: "safari")
                        .font(.subheadline)
                }
            }
            Text(hint).font(.footnote).foregroundStyle(.secondary)
            SecureField("Key einfügen", text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(16)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: 520)
    }

    private func finish() {
        if !key.trimmed.isEmpty { settings.setKey(key, for: .claude) }
        if !openRouterKey.trimmed.isEmpty { settings.setKey(openRouterKey, for: .openrouter) }
        if !key.trimmed.isEmpty {
            settings.provider = .claude
        } else if !openRouterKey.trimmed.isEmpty {
            settings.provider = .openrouter
        }
        settings.autoFallback = true
        settings.hasOnboarded = true
        Haptics.success()
        dismiss()
    }
}
