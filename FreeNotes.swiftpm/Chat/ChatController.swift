import SwiftUI

@MainActor
final class ChatController: ObservableObject {
    let store: LibraryStore
    let settings: AISettings
    let subject: String?

    @Published var threadID: UUID
    @Published private(set) var isStreaming = false
    @Published private(set) var activeModel: String?

    private var task: Task<Void, Never>?

    init(store: LibraryStore, settings: AISettings, threadID: UUID, subject: String? = nil) {
        self.store = store
        self.settings = settings
        self.threadID = threadID
        self.subject = subject
    }

    var thread: ChatThread? { store.thread(threadID) }

    func send(display: String, prompt: String? = nil, images: [UIImage] = [], sourcePage: UIImage? = nil) {
        guard !isStreaming else { return }
        let text = display.trimmed
        guard !text.isEmpty || !images.isEmpty else { return }
        let names = images.compactMap { store.saveChatImage($0) }
        var message = ChatMessage(role: .user, text: text.isEmpty ? "Bild" : text, prompt: prompt, images: names)
        message.sourcePage = sourcePage.flatMap { store.saveChatImage($0) }
        store.updateThread(threadID) { thread in
            thread.messages.append(message)
            if thread.notebookID == nil, thread.title == "Neuer Chat" {
                thread.title = String(message.text.prefix(40))
            }
        }
        run()
    }

    func regenerate() {
        guard !isStreaming else { return }
        store.updateThread(threadID) { thread in
            while let last = thread.messages.last, last.role == .assistant {
                thread.messages.removeLast()
            }
        }
        run()
    }

    func stop() {
        task?.cancel()
    }

    func clear() {
        stop()
        store.updateThread(threadID) { $0.messages.removeAll() }
    }

    private func run() {
        guard let thread else { return }
        let history = apiMessages(for: thread)
        let reply = ChatMessage(role: .assistant, text: "")
        let replyID = reply.id
        store.updateThread(threadID) { $0.messages.append(reply) }
        isStreaming = true
        task = Task { [weak self] in
            await self?.stream(history: history, replyID: replyID)
            self?.isStreaming = false
            self?.activeModel = nil
        }
    }

    private func stream(history: [AIMessage], replyID: UUID) async {
        let providers = settings.providerOrder
        // Mit Bild gründlicher nachdenken (Aufgaben lösen), reine Chat-Fragen sparsam.
        let effort = history.contains { !$0.images.isEmpty } ? "medium" : "low"
        var lastError: Error?
        for (index, provider) in providers.enumerated() {
            do {
                let config = try settings.config(for: provider)
                activeModel = config.model
                let meta = "\(provider.title) · \(config.model)"
                var text = ""
                for try await chunk in AIClient.stream(messages: history, config: config, effort: effort) {
                    switch chunk {
                    case .text(let piece):
                        text += piece
                        update(replyID) { $0.text = text; $0.meta = meta }
                    case .usage(let input, let output):
                        settings.recordClaudeUsage(model: config.model, inputTokens: input, outputTokens: output)
                    }
                }
                if Task.isCancelled { return }
                if text.trimmed.isEmpty { throw AIError.empty }
                Haptics.success()
                return
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                lastError = error
                // Bei jedem Fehler (Limit, Ablehnung, Netz) den nächsten Anbieter versuchen.
                guard index < providers.count - 1 else { break }
                let next = providers[index + 1].title
                update(replyID) { $0.text = ""; $0.meta = "\(provider.title) geht gerade nicht, wechsle zu \(next) …" }
            }
        }
        let message = (lastError as? LocalizedError)?.errorDescription ?? lastError?.localizedDescription ?? "Unbekannter Fehler"
        update(replyID) { $0.text = message; $0.isError = true }
        Haptics.error()
    }

    private func update(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        store.updateThread(threadID) { thread in
            guard let i = thread.messages.firstIndex(where: { $0.id == id }) else { return }
            change(&thread.messages[i])
        }
    }

    /// Baut den Verlauf für die KI. Bilder werden nur aus den letzten Nachrichten mitgeschickt.
    private func apiMessages(for thread: ChatThread) -> [AIMessage] {
        var result = [AIMessage(role: "system", text: PromptBuilder.system(grade: settings.grade, subject: subject))]
        let usable = thread.messages.filter { !$0.isError && !($0.role == .assistant && $0.text.isEmpty) }
        let recent = usable.suffix(20)
        let imageCutoff = recent.count - 6
        for (offset, msg) in recent.enumerated() {
            var images: [String] = []
            if msg.role == .user, offset >= imageCutoff {
                images = msg.images.compactMap { store.chatImage($0)?.jpegBase64() }
            }
            let text = msg.role == .user ? (msg.prompt ?? msg.text) : msg.text
            result.append(AIMessage(role: msg.role.rawValue, text: text, images: images))
        }
        return result
    }
}
