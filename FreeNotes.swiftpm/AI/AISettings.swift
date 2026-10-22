import SwiftUI
import Security

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

@MainActor
final class AISettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var provider: AIProviderKind { didSet { defaults.set(provider.rawValue, forKey: "ai.provider") } }
    @Published var geminiModel: String { didSet { defaults.set(geminiModel, forKey: "ai.model.gemini") } }
    @Published var openRouterModel: String { didSet { defaults.set(openRouterModel, forKey: "ai.model.openrouter") } }
    @Published var autoFallback: Bool { didSet { defaults.set(autoFallback, forKey: "ai.autoFallback") } }
    @Published var grade: String { didSet { defaults.set(grade, forKey: "ai.grade") } }
    @Published var fingerDrawing: Bool { didSet { defaults.set(fingerDrawing, forKey: "pen.finger") } }
    @Published var hasOnboarded: Bool { didSet { defaults.set(hasOnboarded, forKey: "app.onboarded") } }
    @Published private(set) var keyVersion = 0

    static let grades = ["Klasse 5", "Klasse 6", "Klasse 7", "Klasse 8", "Klasse 9", "Klasse 10",
                         "Klasse 11", "Klasse 12", "Klasse 13", "Ausbildung", "Studium"]

    init() {
        provider = AIProviderKind(rawValue: defaults.string(forKey: "ai.provider") ?? "") ?? .gemini
        geminiModel = defaults.string(forKey: "ai.model.gemini") ?? AIProviderKind.gemini.defaultModel
        openRouterModel = defaults.string(forKey: "ai.model.openrouter") ?? AIProviderKind.openrouter.defaultModel
        autoFallback = defaults.object(forKey: "ai.autoFallback") as? Bool ?? true
        grade = defaults.string(forKey: "ai.grade") ?? "Klasse 10"
        fingerDrawing = defaults.bool(forKey: "pen.finger")
        hasOnboarded = defaults.bool(forKey: "app.onboarded")
    }

    func key(for p: AIProviderKind) -> String {
        Keychain.read(account: p.rawValue) ?? ""
    }

    func setKey(_ key: String, for p: AIProviderKind) {
        Keychain.write(key.trimmed, account: p.rawValue)
        keyVersion += 1
    }

    func model(for p: AIProviderKind) -> String {
        let m = (p == .gemini ? geminiModel : openRouterModel).trimmed
        return m.isEmpty ? p.defaultModel : m
    }

    func setModel(_ model: String, for p: AIProviderKind) {
        if p == .gemini { geminiModel = model } else { openRouterModel = model }
    }

    var hasAnyKey: Bool {
        AIProviderKind.allCases.contains { !key(for: $0).isEmpty }
    }

    func config(for p: AIProviderKind) throws -> AIConfig {
        let k = key(for: p)
        guard !k.isEmpty else { throw AIError.missingKey(p.title) }
        return AIConfig(provider: p, model: model(for: p), key: k)
    }

    /// Reihenfolge der Anbieter: gewählter zuerst, der andere als Ausweichlösung.
    var providerOrder: [AIProviderKind] {
        var list = [provider]
        if autoFallback, !key(for: provider.other).isEmpty { list.append(provider.other) }
        return list
    }
}

// MARK: - Schlüsselbund

enum Keychain {
    private static let service = "de.freenotes.app.keys"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let value = String(data: data, encoding: .utf8) {
            return value
        }
        // Ausweichlösung, falls der Schlüsselbund (z. B. in Swift Playgrounds) nicht verfügbar ist.
        return UserDefaults.standard.string(forKey: "fallback.key.\(account)")
    }

    static func write(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "fallback.key.\(account)")
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            UserDefaults.standard.set(value, forKey: "fallback.key.\(account)")
        }
    }
}
