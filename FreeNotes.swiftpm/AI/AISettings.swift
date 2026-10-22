import SwiftUI
import Security

enum PencilAction: String, CaseIterable, Identifiable {
    case ai, eraser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ai: return "KI-Kreis ein/aus"
        case .eraser: return "Radierer ein/aus"
        }
    }
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
    @Published var flipDirection: FlipDirection { didSet { defaults.set(flipDirection.rawValue, forKey: "pages.flip") } }
    @Published var pencilAction: PencilAction { didSet { defaults.set(pencilAction.rawValue, forKey: "pen.action") } }
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
        flipDirection = FlipDirection(rawValue: defaults.string(forKey: "pages.flip") ?? "") ?? .horizontal
        pencilAction = PencilAction(rawValue: defaults.string(forKey: "pen.action") ?? "") ?? .ai
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
