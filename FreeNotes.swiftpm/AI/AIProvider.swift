import Foundation

enum AIProviderKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case gemini, openrouter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .openrouter: return "OpenRouter"
        }
    }

    /// Beide Anbieter sprechen das OpenAI-kompatible Format.
    var baseURL: URL {
        switch self {
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!
        case .openrouter: return URL(string: "https://openrouter.ai/api/v1/")!
        }
    }

    var defaultModel: String {
        switch self {
        case .gemini: return "gemini-flash-latest"
        case .openrouter: return "openrouter/free"
        }
    }

    var keyHelpURL: URL {
        switch self {
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        case .openrouter: return URL(string: "https://openrouter.ai/keys")!
        }
    }

    var limitHint: String {
        switch self {
        case .gemini:
            return "Kostenloser Key von Google AI Studio. Sehr gut bei Mathe und beim Lesen von Bildern. Es gibt Limits pro Minute und pro Tag."
        case .openrouter:
            return "Kostenlose Modelle (»:free« oder »openrouter/free«). Ca. 20 Anfragen pro Minute und 50 pro Tag (1000, wenn man einmal 10 $ Guthaben kauft)."
        }
    }

    var other: AIProviderKind { self == .gemini ? .openrouter : .gemini }
}

struct AIConfig: Sendable {
    let provider: AIProviderKind
    let model: String
    let key: String
}
