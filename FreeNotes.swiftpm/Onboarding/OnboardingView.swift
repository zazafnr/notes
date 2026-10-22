import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var settings: AISettings
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    @State private var key = ""
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
                Text(step < 2 ? "Weiter" : (key.trimmed.isEmpty ? "Später einrichten" : "Los geht's"))
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
        VStack(spacing: 20) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 54))
                .foregroundStyle(Theme.aiGradient)
                .symbolEffect(.bounce, value: step)
            Text("Kostenlosen KI-Key eintragen")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 10) {
                Label("Öffne aistudio.google.com/apikey und melde dich mit Google an.", systemImage: "1.circle.fill")
                Label("Tippe auf »API-Schlüssel erstellen« und kopiere ihn.", systemImage: "2.circle.fill")
                Label("Füge ihn hier ein. Fertig!", systemImage: "3.circle.fill")
            }
            .font(.body)
            .frame(maxWidth: 480, alignment: .leading)
            Link(destination: AIProviderKind.gemini.keyHelpURL) {
                Label("Google AI Studio öffnen", systemImage: "safari")
            }
            SecureField("Gemini-API-Key einfügen", text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: 480)
            Text("Später kannst du in den Einstellungen auch OpenRouter hinzufügen.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(30)
    }

    private func finish() {
        if !key.trimmed.isEmpty {
            settings.setKey(key, for: .gemini)
            settings.provider = .gemini
        }
        settings.hasOnboarded = true
        Haptics.success()
        dismiss()
    }
}
