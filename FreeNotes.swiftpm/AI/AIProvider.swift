import Foundation

enum AIProviderKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case claude, openrouter, gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .gemini: return "Google Gemini"
        case .openrouter: return "OpenRouter"
        }
    }

    /// Gemini und OpenRouter sprechen das OpenAI-kompatible Format, Claude die Anthropic Messages API.
    var baseURL: URL {
        switch self {
        case .claude: return URL(string: "https://api.anthropic.com/v1/")!
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!
        case .openrouter: return URL(string: "https://openrouter.ai/api/v1/")!
        }
    }

    var defaultModel: String {
        switch self {
        case .claude: return ClaudePricing.defaultModel
        case .gemini: return "gemini-flash-latest"
        case .openrouter: return "openrouter/free"
        }
    }

    var keyHelpURL: URL {
        switch self {
        case .claude: return URL(string: "https://console.anthropic.com/settings/keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        case .openrouter: return URL(string: "https://openrouter.ai/keys")!
        }
    }

    var isFree: Bool { self != .claude }

    var limitHint: String {
        switch self {
        case .claude:
            return "Kostenpflichtig, mit Guthaben von console.anthropic.com. Die App verteilt dein Monatsbudget auf die Tage und wechselt danach automatisch zu OpenRouter."
        case .gemini:
            return "Kostenloser Key von Google AI Studio. Sehr gut bei Mathe und beim Lesen von Bildern. Es gibt Limits pro Minute und pro Tag."
        case .openrouter:
            return "Kostenlose Modelle. »openrouter/free« wählt automatisch ein freies Modell, das Bilder lesen kann. Ca. 20 Anfragen pro Minute und 50 pro Tag (1000, wenn man einmal 10 $ Guthaben kauft)."
        }
    }
}

struct AIConfig: Sendable {
    let provider: AIProviderKind
    let model: String
    let key: String
}
