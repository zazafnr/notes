import SwiftUI

/// Erscheint nach dem Einkreisen: Vorschau, Schnellaktionen und eigene Frage.
struct AskSheet: View {
    let snapshot: LassoSnapshot
    var isLatin = false
    var onSend: (_ display: String, _ prompt: String) -> Void
    /// Lösen und die Antwort direkt an der eingekreisten Stelle eintragen.
    var onFill: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var appeared = false
    @FocusState private var focused: Bool
    /// Die Tastatur erscheint erst, wenn man ins Feld tippt.
    @State private var editing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(uiImage: snapshot.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Theme.aiGradient, lineWidth: 2.5)
                        )
                        .shadow(color: Theme.aiColors[1].opacity(0.35), radius: 18, y: 6)
                        .scaleEffect(appeared ? 1 : 0.9)
                        .opacity(appeared ? 1 : 0)

                    if let onFill {
                        Button {
                            Haptics.tap()
                            dismiss()
                            onFill()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "pencil.and.scribble")
                                    .font(.title3.weight(.semibold))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(snapshot.sourcePage != nil ? "Direkt ausfüllen (Buchseite ins Heft)" : "Direkt ausfüllen")
                                        .font(.headline)
                                    Text("Lösen und in deiner Handschrift genau hier eintragen")
                                        .font(.caption)
                                        .opacity(0.85)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.subheadline.weight(.bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(Theme.aiGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(PressableStyle())
                        .offset(y: appeared ? 0 : 16)
                        .opacity(appeared ? 1 : 0)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(Array(QuickAction.available(latin: isLatin).enumerated()), id: \.element.id) { index, action in
                            Button {
                                let extra = question.trimmed
                                let prompt = extra.isEmpty ? action.prompt : action.prompt + "\nZusätzlich: " + extra
                                let display = extra.isEmpty ? action.title : "\(action.title): \(extra)"
                                send(display: display, prompt: prompt)
                            } label: {
                                Label(action.title, systemImage: action.symbol)
                                    .font(.subheadline.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity, minHeight: 22)
                                    .padding(.vertical, 13)
                                    .padding(.horizontal, 8)
                                    .foregroundStyle(action.isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                                    .background(action.isProminent ? AnyShapeStyle(Theme.aiGradient) : AnyShapeStyle(Color.primary.opacity(0.06)),
                                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(PressableStyle())
                            .offset(y: appeared ? 0 : 16)
                            .opacity(appeared ? 1 : 0)
                            .animation(.spring(response: 0.45, dampingFraction: 0.8).delay(0.04 * Double(index)), value: appeared)
                        }
                    }

                    HStack(spacing: 10) {
                        Group {
                            if editing {
                                TextField("Oder frag etwas: „Was bedeutet …?“", text: $question, axis: .vertical)
                                    .lineLimit(1...4)
                                    .focused($focused)
                            } else {
                                Button {
                                    editing = true
                                    Task { @MainActor in focused = true }
                                } label: {
                                    Text("Oder frag etwas: „Was bedeutet …?“")
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        Button {
                            send(display: question.trimmed, prompt: question.trimmed)
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(question.trimmed.isEmpty ? AnyShapeStyle(Color.secondary.opacity(0.4)) : AnyShapeStyle(Theme.aiGradient))
                        }
                        .disabled(question.trimmed.isEmpty)
                    }
                    Text("Tipp: Tippe ins Feld, um eine eigene Frage zu stellen; mit dem Pencil kannst du direkt hineinschreiben.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(22)
            }
            .navigationTitle("Frag die KI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true }
        }
    }

    private func send(display: String, prompt: String) {
        guard !prompt.isEmpty else { return }
        Haptics.tap()
        onSend(display, prompt)
        dismiss()
    }
}
