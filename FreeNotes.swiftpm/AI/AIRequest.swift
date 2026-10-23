import Foundation

/// Eine einzelne KI-Anfrage ohne Chat-Verlauf (z. B. Heft-Text formatieren, Arbeitsblatt auswerten).
/// Probiert wie der Chat die Anbieter der Reihe nach und zählt die Claude-Kosten mit.
@MainActor
enum AIRequest {
    /// `onText`: meldet den bisher angekommenen Text (für eine Fortschrittsanzeige).
    static func text(system: String, user: String, images: [String] = [], settings: AISettings,
                     effort: String = "low", onText: ((String) -> Void)? = nil,
                     onStatus: ((String) -> Void)? = nil) async throws -> String {
        let messages = [AIMessage(role: "system", text: system), AIMessage(role: "user", text: user, images: images)]
        var lastError: Error = AIError.empty
        let providers = settings.providerOrder
        for (index, provider) in providers.enumerated() {
            do {
                let config = try settings.config(for: provider)
                onStatus?("Frage \(provider.title) (\(config.model)) …")
                var text = ""
                for try await chunk in AIClient.stream(messages: messages, config: config, effort: effort) {
                    switch chunk {
                    case .text(let piece):
                        text += piece
                        onText?(text)
                    case .usage(let input, let output):
                        settings.recordClaudeUsage(model: config.model, inputTokens: input, outputTokens: output)
                    }
                }
                try Task.checkCancellation()
                if text.trimmed.isEmpty { throw AIError.empty }
                return text
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                if index + 1 < providers.count {
                    let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    onStatus?("\(provider.title): \(reason) – versuche \(providers[index + 1].title) …")
                }
            }
        }
        throw lastError
    }
}
