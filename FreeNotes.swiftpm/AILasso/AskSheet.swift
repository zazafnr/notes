import SwiftUI

/// Erscheint nach dem Einkreisen: Vorschau, Schnellaktionen und eigene Frage.
struct AskSheet: View {
    let snapshot: LassoSnapshot
    var onSend: (_ display: String, _ prompt: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var appeared = false
    @FocusState private var focused: Bool

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

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(Array(QuickAction.allCases.enumerated()), id: \.element.id) { index, action in
                            Button {
                                let extra = question.trimmed
                                let prompt = extra.isEmpty ? action.prompt : action.prompt + "\nZusätzlich: " + extra
                                let display = extra.isEmpty ? action.title : "\(action.title): \(extra)"
                                send(display: display, prompt: prompt)
                            } label: {
                                Label(action.title, systemImage: action.symbol)
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 13)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(PressableStyle())
                            .offset(y: appeared ? 0 : 16)
                            .opacity(appeared ? 1 : 0)
                            .animation(.spring(response: 0.45, dampingFraction: 0.8).delay(0.04 * Double(index)), value: appeared)
                        }
                    }

                    HStack(spacing: 10) {
                        TextField("Oder frag etwas: „Was bedeutet …?“", text: $question, axis: .vertical)
                            .lineLimit(1...4)
                            .focused($focused)
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
                    Text("Tipp: Du kannst mit dem Pencil direkt ins Feld schreiben.")
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
