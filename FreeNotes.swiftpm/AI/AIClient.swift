import Foundation

struct AIMessage: Sendable {
    var role: String
    var text: String
    /// JPEG-Bilder als Base64.
    var images: [String] = []
}

enum AIError: LocalizedError {
    case missingKey(String)
    case rateLimited(String)
    case invalidKey(String)
    case http(Int, String)
    case empty

    var isRateLimit: Bool {
        if case .rateLimited = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider):
            return "Für \(provider) ist noch kein API-Key eingetragen. Öffne die Einstellungen (Zahnrad) und füge deinen kostenlosen Key ein."
        case .rateLimited(let msg):
            return "Limit erreicht: Der Anbieter lässt gerade keine weiteren Anfragen zu. Warte kurz oder wechsle in den Einstellungen den Anbieter.\n\n\(msg)"
        case .invalidKey(let msg):
            return "Der API-Key wurde abgelehnt. Prüfe ihn in den Einstellungen.\n\n\(msg)"
        case .http(let code, let msg):
            return "Fehler \(code) vom KI-Anbieter.\n\n\(msg)"
        case .empty:
            return "Die KI hat keine Antwort geschickt. Versuch es noch einmal oder wähle ein anderes Modell."
        }
    }
}

/// Einfacher Client für OpenAI-kompatible Chat-Schnittstellen (Gemini, OpenRouter).
enum AIClient {
    static func stream(messages: [AIMessage], config: AIConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(messages: messages, config: config)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line + "\n"
                            if body.count > 4000 { break }
                        }
                        throw makeError(status: status, body: body)
                    }
                    lines: for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        switch parseEvent(line) {
                        case .text(let content): continuation.yield(content)
                        case .done: break lines
                        case .error(let payload): throw makeError(status: 500, body: payload)
                        case nil: continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    enum StreamEvent: Equatable {
        case text(String)
        case done
        case error(String)
    }

    /// Wertet eine Zeile des Server-Sent-Events-Streams aus.
    static func parseEvent(_ line: String) -> StreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if json["error"] != nil { return .error(payload) }
        guard let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String, !content.isEmpty else { return nil }
        return .text(content)
    }

    static func makeRequest(messages: [AIMessage], config: AIConfig) throws -> URLRequest {
        var request = URLRequest(url: config.provider.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
        if config.provider == .openrouter {
            request.setValue("https://github.com/zazafnr/notes", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("FreeNotes", forHTTPHeaderField: "X-Title")
        }
        let body: [String: Any] = [
            "model": config.model,
            "stream": true,
            "messages": messages.map(encode),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func encode(_ message: AIMessage) -> [String: Any] {
        if message.images.isEmpty {
            return ["role": message.role, "content": message.text]
        }
        var parts: [[String: Any]] = [["type": "text", "text": message.text]]
        for img in message.images {
            parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(img)"]])
        }
        return ["role": message.role, "content": parts]
    }

    static func makeError(status: Int, body: String) -> AIError {
        let message = errorMessage(from: body)
        switch status {
        case 429: return .rateLimited(message)
        case 401, 403: return .invalidKey(message)
        default:
            if message.localizedCaseInsensitiveContains("rate limit") || message.localizedCaseInsensitiveContains("quota") {
                return .rateLimited(message)
            }
            return .http(status, message)
        }
    }

    /// Holt die lesbare Fehlermeldung aus der Antwort (verschiedene Formate je Anbieter).
    static func errorMessage(from body: String) -> String {
        let trimmed = body.trimmed
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return String(trimmed.prefix(400))
        }
        let object: Any = (json as? [Any])?.first ?? json
        if let dict = object as? [String: Any] {
            if let err = dict["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
            if let msg = dict["message"] as? String { return msg }
        }
        return String(trimmed.prefix(400))
    }

    /// Lädt die Modellliste. Bei OpenRouter nur kostenlose Modelle.
    static func fetchModels(config: AIConfig) async throws -> [String] {
        var request = URLRequest(url: config.provider.baseURL.appendingPathComponent("models"))
        request.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw makeError(status: status, body: String(data: data, encoding: .utf8) ?? "") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return [] }
        var ids: [String] = []
        for entry in list {
            guard var id = entry["id"] as? String else { continue }
            if id.hasPrefix("models/") { id = String(id.dropFirst(7)) }
            switch config.provider {
            case .gemini:
                guard id.contains("gemini"), !id.contains("embedding"), !id.contains("tts"), !id.contains("image") else { continue }
            case .openrouter:
                guard id.hasSuffix(":free") || id == "openrouter/free" else { continue }
                if let arch = entry["architecture"] as? [String: Any],
                   let inputs = arch["input_modalities"] as? [String], !inputs.contains("image") { continue }
            }
            ids.append(id)
        }
        return ids.sorted()
    }
}
