import Foundation

/// Preise der Claude-Modelle in US-Dollar pro 1 Million Tokens (Stand Oktober 2026).
enum ClaudePricing {
    struct Model: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let inputPerMillion: Double
        let outputPerMillion: Double
    }

    static let defaultModel = "claude-sonnet-5-5"

    static let models: [Model] = [
        Model(id: "claude-sonnet-5-5", title: "Sonnet 5.5 · empfohlen", inputPerMillion: 2, outputPerMillion: 10),
        Model(id: "claude-haiku-5-5", title: "Haiku 5.5 · sehr günstig", inputPerMillion: 0.10, outputPerMillion: 0.50),
        Model(id: "claude-opus-5-5", title: "Opus 5.5 · am stärksten", inputPerMillion: 4, outputPerMillion: 20),
    ]

    /// Unbekannte Modelle werden vorsichtshalber mit dem teuersten Preis gerechnet.
    static func model(_ id: String) -> Model {
        models.first { $0.id == id } ?? models.max { $0.outputPerMillion < $1.outputPerMillion }!
    }

    static func cost(model id: String, inputTokens: Int, outputTokens: Int) -> Double {
        let m = model(id)
        return Double(inputTokens) * m.inputPerMillion / 1_000_000 + Double(outputTokens) * m.outputPerMillion / 1_000_000
    }

    /// Typische Anfrage: eingekreister Ausschnitt + Frage (~1500 Tokens) und Antwort mit Nachdenken (~1500 Tokens).
    static func typicalCost(model id: String) -> Double {
        cost(model: id, inputTokens: 1500, outputTokens: 1500)
    }
}

/// Anthropic Messages API (eigenes Format, nicht OpenAI-kompatibel).
enum ClaudeClient {
    static let apiVersion = "2026-10-21"
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    /// Begrenzt die Kosten einer einzelnen Antwort.
    static let maxTokens = 6000

    /// Modelle, die bei einer Ablehnung serverseitig auf ein anderes Claude-Modell ausweichen können.
    static func supportsServerFallback(_ model: String) -> Bool {
        model == "claude-sonnet-5-5" || model == "claude-opus-5-5"
    }

    static func makeRequest(messages: [AIMessage], config: AIConfig, effort: String) throws -> URLRequest {
        var request = URLRequest(url: config.provider.baseURL.appendingPathComponent("messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        let system = messages.filter { $0.role == "system" }.map(\.text).joined(separator: "\n\n")
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": conversation(messages),
            "output_config": ["effort": effort],
        ]
        if !system.isEmpty { body["system"] = system }
        if supportsServerFallback(config.model) {
            request.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Baut den Verlauf: beginnt mit dem Schüler, gleiche Rollen hintereinander werden zusammengelegt.
    static func conversation(_ messages: [AIMessage]) -> [[String: Any]] {
        var result: [(role: String, blocks: [[String: Any]])] = []
        for message in messages where message.role == "user" || message.role == "assistant" {
            var blocks: [[String: Any]] = message.images.map { image in
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image]]
            }
            if !message.text.isEmpty { blocks.append(["type": "text", "text": message.text]) }
            guard !blocks.isEmpty else { continue }
            if result.isEmpty && message.role != "user" { continue }
            if let last = result.last, last.role == message.role {
                result[result.count - 1].blocks.append(contentsOf: blocks)
            } else {
                result.append((message.role, blocks))
            }
        }
        return result.map { ["role": $0.role, "content": $0.blocks] }
    }

    enum Event: Equatable {
        case text(String)
        case usage(input: Int?, output: Int?)
        case stop(String)
        case error(String)
    }

    /// Wertet eine Zeile des Streams aus (nur die »data:«-Zeilen sind wichtig).
    static func parseEvents(_ line: String) -> [Event] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return [] }
        switch type {
        case "message_start":
            guard let usage = (json["message"] as? [String: Any])?["usage"] as? [String: Any] else { return [] }
            return [.usage(input: inputTokens(usage), output: usage["output_tokens"] as? Int)]
        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else { return [] }
            return [.text(text)]
        case "message_delta":
            var events: [Event] = []
            if let usage = json["usage"] as? [String: Any] {
                let input = inputTokens(usage)
                events.append(.usage(input: input == 0 ? nil : input, output: usage["output_tokens"] as? Int))
            }
            if let reason = (json["delta"] as? [String: Any])?["stop_reason"] as? String {
                events.append(.stop(reason))
            }
            return events
        case "error":
            return [.error(payload)]
        default:
            return []
        }
    }

    private static func inputTokens(_ usage: [String: Any]) -> Int {
        ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
            .compactMap { usage[$0] as? Int }
            .reduce(0, +)
    }

    /// Lädt die verfügbaren Claude-Modelle.
    static func fetchModels(config: AIConfig) async throws -> [String] {
        var request = URLRequest(url: config.provider.baseURL.appendingPathComponent("models"))
        request.setValue(config.key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw AIClient.makeError(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["id"] as? String }
    }
}
