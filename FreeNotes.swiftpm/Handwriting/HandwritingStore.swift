import SwiftUI

/// Wie schnell die Handschrift vorgeschrieben wird.
enum HWSpeed: String, CaseIterable, Identifiable {
    case real, fast, veryFast, instant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .real: return "Echt"
        case .fast: return "Schnell"
        case .veryFast: return "Sehr schnell"
        case .instant: return "Sofort"
        }
    }

    /// Faktor gegenüber echtem Schreibtempo (nil = ohne Animation).
    var factor: Double? {
        switch self {
        case .real: return 1
        case .fast: return 2.2
        case .veryFast: return 4.5
        case .instant: return nil
        }
    }
}

/// Eigene Buchstaben und Einstellungen für die Handschrift.
/// Gespeichert in Documents/FreeNotes/handwriting.json (ist damit auch im Backup).
@MainActor
final class HandwritingStore: ObservableObject {
    static let shared = HandwritingStore()

    private let defaults = UserDefaults.standard
    private let url: URL

    /// Schriftgröße im Verhältnis zur Lineatur (0,8 … 1,25).
    @Published var size: Double { didSet { defaults.set(size, forKey: "hw.size") } }
    /// 0 = sehr ordentlich, 1 = schnell hingeschrieben.
    @Published var messiness: Double { didSet { defaults.set(messiness, forKey: "hw.messiness") } }
    @Published var speed: HWSpeed { didSet { defaults.set(speed.rawValue, forKey: "hw.speed") } }
    /// Selbst geschriebene Buchstaben (ersetzen die aus der Schriftprobe).
    @Published private(set) var custom: [String: [HWGlyph]] = [:] { didSet { cachedFont = nil } }

    private var cachedFont: HandwritingFont?

    private struct FileData: Codable {
        var glyphs: [String: [HWGlyph]]
    }

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = docs.appendingPathComponent("FreeNotes/handwriting.json")
        size = defaults.object(forKey: "hw.size") as? Double ?? 1
        messiness = defaults.object(forKey: "hw.messiness") as? Double ?? 0.45
        speed = HWSpeed(rawValue: defaults.string(forKey: "hw.speed") ?? "") ?? .fast
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(FileData.self, from: data) {
            custom = file.glyphs
        }
    }

    var font: HandwritingFont {
        if let cachedFont { return cachedFont }
        let font = HandwritingFont.builtIn.merged(with: custom)
        cachedFont = font
        return font
    }

    func style(xHeight: Double) -> HWStyle {
        HWStyle(xHeight: xHeight, messiness: messiness)
    }

    func setCustom(_ variants: [HWGlyph], for key: String) {
        if variants.isEmpty { custom[key] = nil } else { custom[key] = variants }
        save()
    }

    func resetCustom() {
        custom = [:]
        save()
    }

    /// Nach dem Wiederherstellen eines Backups neu einlesen.
    func reload() {
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(FileData.self, from: data) {
            custom = file.glyphs
        } else {
            custom = [:]
        }
    }

    private func save() {
        let file = FileData(glyphs: custom)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Alle Zeichen, die man selbst schreiben kann (in Gruppen für die Übersicht).
    static let trainingGroups: [(title: String, characters: [String])] = [
        ("Kleinbuchstaben", "abcdefghijklmnopqrstuvwxyzäöüß".map(String.init)),
        ("Großbuchstaben", "ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÜ".map(String.init)),
        ("Ziffern", "0123456789".map(String.init)),
        ("Zeichen", ".,:;!?-+=()/%°·×÷√π≈≠<>→".map(String.init)),
    ]
}
