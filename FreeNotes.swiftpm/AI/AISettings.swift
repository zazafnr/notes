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
    @Published var claudeModel: String { didSet { defaults.set(claudeModel, forKey: "ai.model.claude") } }
    @Published var autoFallback: Bool { didSet { defaults.set(autoFallback, forKey: "ai.autoFallback") } }
    @Published var grade: String { didSet { defaults.set(grade, forKey: "ai.grade") } }
    @Published var fingerDrawing: Bool { didSet { defaults.set(fingerDrawing, forKey: "pen.finger") } }
    @Published var hasOnboarded: Bool { didSet { defaults.set(hasOnboarded, forKey: "app.onboarded") } }
    @Published var flipDirection: FlipDirection { didSet { defaults.set(flipDirection.rawValue, forKey: "pages.flip") } }
    @Published var pencilAction: PencilAction { didSet { defaults.set(pencilAction.rawValue, forKey: "pen.action") } }
    @Published private(set) var keyVersion = 0
    /// Geschätzte Claude-Kosten in diesem Monat (US-Dollar, aus den gemeldeten Tokens).
    @Published private(set) var claudeSpent: Double
    /// Kurzer Hinweis, wenn wieder 0,50 $ zusammengekommen sind.
    @Published var costNotice: String?
    private var claudeMonth: String
    private var claudeNotifiedSteps: Int
    static let noticeStep = 0.5

    static let grades = ["Klasse 5", "Klasse 6", "Klasse 7", "Klasse 8", "Klasse 9", "Klasse 10",
                         "Klasse 11", "Klasse 12", "Klasse 13", "Ausbildung", "Studium"]

    init() {
        provider = AIProviderKind(rawValue: defaults.string(forKey: "ai.provider") ?? "") ?? .claude
        geminiModel = defaults.string(forKey: "ai.model.gemini") ?? AIProviderKind.gemini.defaultModel
        openRouterModel = defaults.string(forKey: "ai.model.openrouter") ?? AIProviderKind.openrouter.defaultModel
        claudeModel = defaults.string(forKey: "ai.model.claude") ?? AIProviderKind.claude.defaultModel
        claudeSpent = defaults.double(forKey: "ai.claude.spent")
        claudeMonth = defaults.string(forKey: "ai.claude.month") ?? ""
        claudeNotifiedSteps = defaults.integer(forKey: "ai.claude.notified")
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
        let m: String
        switch p {
        case .claude: m = claudeModel.trimmed
        case .gemini: m = geminiModel.trimmed
        case .openrouter: m = openRouterModel.trimmed
        }
        return m.isEmpty ? p.defaultModel : m
    }

    func setModel(_ model: String, for p: AIProviderKind) {
        switch p {
        case .claude: claudeModel = model
        case .gemini: geminiModel = model
        case .openrouter: openRouterModel = model
        }
    }

    // MARK: Claude-Verbrauch (nur Anzeige, kein Limit)

    private static func monthKey(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// Zählt die Kosten einer Antwort und meldet sich bei jeweils 0,50 $.
    func recordClaudeUsage(model: String, inputTokens: Int, outputTokens: Int) {
        let month = Self.monthKey()
        if month != claudeMonth {
            claudeMonth = month
            claudeSpent = 0
            claudeNotifiedSteps = 0
        }
        claudeSpent += ClaudePricing.cost(model: model, inputTokens: inputTokens, outputTokens: outputTokens)
        let steps = Int(claudeSpent / Self.noticeStep)
        if steps > claudeNotifiedSteps {
            claudeNotifiedSteps = steps
            costNotice = "Claude diesen Monat: \(Self.dollar(Double(steps) * Self.noticeStep))"
        }
        saveClaudeUsage()
    }

    func resetClaudeUsage() {
        claudeSpent = 0
        claudeNotifiedSteps = 0
        claudeMonth = Self.monthKey()
        saveClaudeUsage()
    }

    private func saveClaudeUsage() {
        defaults.set(claudeSpent, forKey: "ai.claude.spent")
        defaults.set(claudeMonth, forKey: "ai.claude.month")
        defaults.set(claudeNotifiedSteps, forKey: "ai.claude.notified")
    }

    /// Verbrauch dieses Monats (0, wenn ein neuer Monat begonnen hat).
    var claudeSpentThisMonth: Double {
        claudeMonth == Self.monthKey() ? claudeSpent : 0
    }

    static func dollar(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(Locale(identifier: "de_DE")))
    }

    var hasAnyKey: Bool {
        AIProviderKind.allCases.contains { !key(for: $0).isEmpty }
    }

    func config(for p: AIProviderKind) throws -> AIConfig {
        let k = key(for: p)
        guard !k.isEmpty else { throw AIError.missingKey(p.title) }
        return AIConfig(provider: p, model: model(for: p), key: k)
    }

    /// Reihenfolge der Anbieter: gewählter zuerst, bei Fehlern (falls eingeschaltet) die anderen mit Key.
    var providerOrder: [AIProviderKind] {
        var list = [provider]
        if autoFallback {
            let others: [AIProviderKind] = [.claude, .openrouter, .gemini]
            list += others.filter { $0 != provider && !key(for: $0).isEmpty }
        }
        return list
    }

    /// Anbieter, für die ein Key eingetragen ist (für die Schnellauswahl im KI-Fenster).
    var configuredProviders: [AIProviderKind] {
        AIProviderKind.allCases.filter { !key(for: $0).isEmpty }
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
