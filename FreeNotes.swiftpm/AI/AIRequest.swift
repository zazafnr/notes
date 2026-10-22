import Foundation

/// Eine einzelne KI-Anfrage ohne Chat-Verlauf (z. B. Heft-Text formatieren, Arbeitsblatt auswerten).
/// Probiert wie der Chat die Anbieter der Reihe nach und zählt die Claude-Kosten mit.
@MainActor
enum AIRequest {
    /// `onText`: meldet, wie viele Zeichen schon angekommen sind (für eine Fortschrittsanzeige).
    static func text(system: String, user: String, images: [String] = [], settings: AISettings,
                     effort: String = "low", onText: ((Int) -> Void)? = nil) async throws -> String {
        let messages = [AIMessage(role: "system", text: system), AIMessage(role: "user", text: user, images: images)]
        var lastError: Error = AIError.empty
        for provider in settings.providerOrder {
            do {
                let config = try settings.config(for: provider)
                var text = ""
                for try await chunk in AIClient.stream(messages: messages, config: config, effort: effort) {
                    switch chunk {
                    case .text(let piece):
                        text += piece
                        onText?(text.count)
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
            }
        }
        throw lastError
    }
}
