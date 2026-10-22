import SwiftUI
import PhotosUI

/// KI-Chat: im Editor als Seitenleiste, in der Bibliothek als eigene Ansicht.
struct AIPanelView: View {
    @ObservedObject var chat: ChatController
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AISettings
    var title: String
    var onClose: (() -> Void)? = nil
    /// Antwort ins Heft übernehmen (Antwort, zugehörige Frage, Art).
    var onInsert: ((ChatMessage, ChatMessage?, InsertMode) -> Void)? = nil
    var pageImage: (() -> UIImage?)? = nil

    @State private var input = ""
    @State private var attachments: [UIImage] = []
    @State private var photoItem: PhotosPickerItem?
    @FocusState private var focused: Bool

    private var messages: [ChatMessage] { chat.thread?.messages ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            messageList
            composer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.aiGradient).frame(width: 34, height: 34)
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: chat.isStreaming)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).lineLimit(1)
                Text(chat.isStreaming ? "schreibt …" : "KI-Assistent · \(settings.provider.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            Menu {
                Section("KI-Anbieter") {
                    ForEach(AIProviderKind.allCases) { p in
                        Button {
                            settings.provider = p
                            Haptics.tap()
                        } label: {
                            if settings.provider == p {
                                Label(p.title, systemImage: "checkmark")
                            } else {
                                Text(p.title + (settings.key(for: p).isEmpty ? " (kein Key)" : ""))
                            }
                        }
                        .disabled(settings.key(for: p).isEmpty)
                    }
                }
                Button(role: .destructive) { chat.clear() } label: {
                    Label("Verlauf leeren", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if messages.isEmpty {
                        emptyState
                    }
                    ForEach(messages) { message in
                        MessageRow(message: message,
                                   isLast: message.id == messages.last?.id,
                                   isStreaming: chat.isStreaming,
                                   onInsert: insertAction(for: message),
                                   fromBook: question(before: message.id)?.sourcePage != nil,
                                   fromPage: question(before: message.id)?.sourcePageID != nil,
                                   onRegenerate: { chat.regenerate() })
                            .id(message.id)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: messages.count)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.last?.text) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Theme.aiGradient)
                .symbolEffect(.bounce, value: messages.isEmpty)
            Text("Frag mich etwas")
                .font(.title3.weight(.semibold))
            Text("Kreise im Heft eine Aufgabe mit ✨ ein oder stell hier direkt eine Frage.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                ForEach(["Erklär mir den Satz des Pythagoras", "Wie schreibe ich eine gute Erörterung?", "Was ist Photosynthese?"], id: \.self) { s in
                    Button { chat.send(display: s) } label: {
                        Text(s)
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { index, img in
                            Image(uiImage: img)
                                .resizable().scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(alignment: .topTrailing) {
                                    Button { attachments.remove(at: index) } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .offset(x: 6, y: -6)
                                }
                        }
                    }
                    .padding(.top, 6)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    if let pageImage {
                        Button {
                            if let img = pageImage() { attachments.append(img) }
                        } label: { Label("Aktuelle Seite anhängen", systemImage: "doc.richtext") }
                    }
                    Button {
                        if let img = UIPasteboard.general.image { attachments.append(img) }
                    } label: { Label("Bild einfügen", systemImage: "doc.on.clipboard") }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                }
                TextField("Frag etwas …", text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .onSubmit(send)
                if chat.isStreaming {
                    Button { chat.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 30))
                    }
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(canSend ? AnyShapeStyle(Theme.aiGradient) : AnyShapeStyle(Color.secondary.opacity(0.4)))
                    }
                    .disabled(!canSend)
                }
            }
        }
        .padding(12)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    attachments.append(img)
                }
                photoItem = nil
            }
        }
    }

    private func insertAction(for message: ChatMessage) -> ((InsertMode) -> Void)? {
        guard let onInsert else { return nil }
        let question = question(before: message.id)
        return { mode in onInsert(message, question, mode) }
    }

    /// Die Frage, auf die eine Antwort gehört (letzte Nachricht des Nutzers davor).
    private func question(before id: UUID) -> ChatMessage? {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
        return messages[..<index].last { $0.role == .user }
    }

    private var canSend: Bool {
        !input.trimmed.isEmpty || !attachments.isEmpty
    }

    private func send() {
        guard canSend, !chat.isStreaming else { return }
        chat.send(display: input, images: attachments)
        input = ""
        attachments = []
        Haptics.tap()
    }
}

struct MessageRow: View {
    @EnvironmentObject private var store: LibraryStore
    let message: ChatMessage
    let isLast: Bool
    let isStreaming: Bool
    var onInsert: ((InsertMode) -> Void)?
    /// Die Frage kam aus dem Buch (ganze Buchseite vorhanden).
    var fromBook = false
    /// Die Frage wurde auf einer Heftseite eingekreist.
    var fromPage = false
    var onRegenerate: () -> Void

    @State private var copied = false

    var body: some View {
        if message.role == .user {
            userBubble
        } else {
            assistantBubble
        }
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(message.images, id: \.self) { name in
                if let img = store.chatImage(name) {
                    Image(uiImage: img)
                        .resizable().scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.aiGradient, lineWidth: 1.5))
                }
            }
            Text(message.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(.white)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.text.isEmpty {
                HStack(spacing: 8) {
                    ThinkingDots()
                    if let meta = message.meta {
                        Text(meta).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if message.isError {
                Label {
                    Text(message.text).font(.subheadline)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .padding(12)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                if isLast, !isStreaming {
                    Button("Erneut versuchen", action: onRegenerate).font(.subheadline.weight(.semibold))
                }
            } else {
                if isLast && isStreaming {
                    MarkdownText(text: message.text)
                } else if LatexLite.containsMath(message.text) {
                    MathMarkdownView(text: message.text)
                } else {
                    MarkdownText(text: message.text)
                        .textSelection(.enabled)
                }
                if !(isLast && isStreaming) {
                    actions
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 14) {
            if let onInsert {
                // Tippen: in Handschrift ins Heft; gedrückt halten: weitere Möglichkeiten
                Menu {
                    Button { onInsert(.handwriting) } label: {
                        Label("In meiner Handschrift ins Heft", systemImage: "pencil.and.scribble")
                    }
                    Button { onInsert(.worksheet) } label: {
                        Label(fromBook ? "Buchseite ins Heft & ausfüllen" : (fromPage ? "Auf dem Zettel an der Stelle eintragen" : "Auf dem Zettel eintragen"),
                              systemImage: "doc.text.viewfinder")
                    }
                    Button { onInsert(.card) } label: {
                        Label("Als Karte einfügen", systemImage: "square.and.arrow.down.on.square")
                    }
                } label: {
                    Label("Ins Heft", systemImage: "pencil.and.scribble")
                } primaryAction: {
                    onInsert(.handwriting)
                }
            }
            Button {
                UIPasteboard.general.string = message.text
                copied = true
                Haptics.tap()
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            } label: {
                Label(copied ? "Kopiert" : "Kopieren", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            if isLast {
                Button(action: onRegenerate) { Label("Neu", systemImage: "arrow.clockwise") }
            }
            Spacer()
            if let meta = message.meta {
                Text(meta).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
    }
}

/// Wie eine KI-Antwort ins Heft kommt.
enum InsertMode {
    /// Buchstabe für Buchstabe in der eigenen Handschrift.
    case handwriting
    /// In die Lücken des Arbeitsblatts auf der aktuellen Seite.
    case worksheet
    /// Als Bild-Karte (wie bisher).
    case card
}

struct ThinkingDots: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Theme.aiGradient)
                    .frame(width: 8, height: 8)
                    .scaleEffect(animate ? 1 : 0.5)
                    .opacity(animate ? 1 : 0.4)
                    .animation(.easeInOut(duration: 0.55).repeatForever().delay(Double(i) * 0.18), value: animate)
            }
        }
        .padding(.vertical, 6)
        .onAppear { animate = true }
    }
}
