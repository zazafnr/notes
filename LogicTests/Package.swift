// swift-tools-version: 5.9

// Testet die Logik der App (ohne Oberfläche) auf dem Mac.
// Die Quelldateien sind Verknüpfungen auf die Dateien in FreeNotes.swiftpm.
import PackageDescription

let package = Package(
    name: "FreeNotesLogic",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "FreeNotesLogic"),
        .testTarget(name: "FreeNotesLogicTests", dependencies: ["FreeNotesLogic"]),
    ]
)
