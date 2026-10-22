import Foundation
import CoreGraphics

// MARK: - Papier

enum PaperStyle: String, Codable, CaseIterable, Identifiable {
    case blank, lined, grid, dotted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: return "Blanko"
        case .lined: return "Liniert"
        case .grid: return "Kariert"
        case .dotted: return "Punkte"
        }
    }

    var symbol: String {
        switch self {
        case .blank: return "doc"
        case .lined: return "text.alignleft"
        case .grid: return "squareshape.split.3x3"
        case .dotted: return "circle.grid.3x3"
        }
    }
}

enum FlipDirection: String, Codable, CaseIterable, Identifiable {
    case horizontal, vertical
    var id: String { rawValue }
    var title: String { self == .horizontal ? "Seitlich wischen" : "Nach oben/unten wischen" }
}

// MARK: - Bibliothek

struct Subject: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var colorIndex: Int
    var symbol: String
}

struct PageImageItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var asset: String
    var frame: CGRect
    /// Drehung in Bogenmaß (fehlt in älteren Dateien).
    var rotation: Double? = nil

    var angle: CGFloat { CGFloat(rotation ?? 0) }
    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    /// Umschließendes Rechteck nach der Drehung (für Treffer-Tests).
    var boundingBox: CGRect {
        frame.applying(CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
    }

    /// Liegt der Punkt (Seitenkoordinaten) auf dem gedrehten Bild?
    func contains(_ point: CGPoint) -> Bool {
        let local = point.applying(CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(rotationAngle: -angle)))
        return CGRect(x: -frame.width / 2, y: -frame.height / 2, width: frame.width, height: frame.height).contains(local)
    }
}

/// Maße auf der Seite: Eine Seite ist 1000 Punkte breit, das entspricht A4 (21 cm).
enum PageMetrics {
    static let pointsPerCentimeter: CGFloat = CGFloat(Page.defaultWidth) / 21

    static func centimeters(_ points: CGFloat) -> CGFloat { points / pointsPerCentimeter }
}

struct Page: Codable, Identifiable, Equatable {
    static let defaultWidth: Double = 1000
    static let defaultHeight: Double = 1414   // A4-Format

    var id = UUID()
    var paper: PaperStyle
    /// Dateiname eines Hintergrundbildes (Scan, PDF-Seite oder Bildseite).
    var background: String? = nil
    var width: Double = Page.defaultWidth
    var height: Double = Page.defaultHeight
    var items: [PageImageItem] = []
    var modified = Date()

    var size: CGSize { CGSize(width: width, height: height) }
    var bounds: CGRect { CGRect(origin: .zero, size: size) }
}

struct Notebook: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var subjectID: UUID?
    var colorIndex: Int
    var paper: PaperStyle
    var pages: [Page]
    var isFavorite = false
    var created = Date()
    var modified = Date()
    var opened: Date? = nil
    var lastPage: Int? = nil
    /// Per Texterkennung gelesene Handschrift und Scans, für die Suche.
    var searchText: String? = nil
}

struct LibraryData: Codable {
    var subjects: [Subject]
    var notebooks: [Notebook]
}

// MARK: - KI-Chat

enum ChatRole: String, Codable {
    case user, assistant
}

struct ChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: ChatRole
    /// Text, der im Chat angezeigt wird.
    var text: String
    /// Text, der tatsächlich an die KI geschickt wird (falls abweichend).
    var prompt: String? = nil
    var images: [String] = []
    var isError = false
    var meta: String? = nil
    var date = Date()
}

struct ChatThread: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var notebookID: UUID? = nil
    var messages: [ChatMessage] = []
    var created = Date()
    var updated = Date()
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
