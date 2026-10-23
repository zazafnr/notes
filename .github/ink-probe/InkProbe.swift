// Misst, wie PencilKit programmatisch erzeugte Striche zeichnet (Breite und Schwärze),
// damit die KI-Handschrift nicht geraten werden muss. Läuft in der CI auf dem Mac und im iPad-Simulator.
import Foundation
import PencilKit
#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
#else
import AppKit
typealias PlatformColor = NSColor
#endif

struct Config {
    var ink: PKInk.InkType
    var name: String
    var size: CGFloat
    var force: CGFloat = 1
    /// Punkte pro Sekunde (0 = alle Punkte zur selben Zeit)
    var speed: Double = 190
    var altitude: CGFloat = .pi / 2
    var opacity: CGFloat = 1
    var step: CGFloat = 0.8
}

func stroke(_ c: Config, color: PlatformColor = .black) -> PKStroke {
    let a = CGPoint(x: 20, y: 10), b = CGPoint(x: 20, y: 90)
    let length = b.y - a.y
    let n = max(2, Int(length / c.step))
    var points: [PKStrokePoint] = []
    for i in 0...n {
        let t = CGFloat(i) / CGFloat(n)
        let p = CGPoint(x: a.x, y: a.y + length * t)
        let d = Double(length * t)
        points.append(PKStrokePoint(location: p, timeOffset: c.speed > 0 ? d / c.speed : 0,
                                    size: CGSize(width: c.size, height: c.size), opacity: c.opacity,
                                    force: c.force, azimuth: 0, altitude: c.altitude))
    }
    return PKStroke(ink: PKInk(c.ink, color: color), path: PKStrokePath(controlPoints: points, creationDate: Date()))
}

func render(_ drawing: PKDrawing, rect: CGRect, scale: CGFloat, dark: Bool) -> CGImage? {
    #if canImport(UIKit)
    var image = UIImage()
    UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent {
        image = drawing.image(from: rect, scale: scale)
    }
    return image.cgImage
    #else
    var image = NSImage()
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        image = drawing.image(from: rect, scale: scale)
    }
    var r = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &r, context: nil, hints: nil)
    #endif
}

struct Measure {
    /// Dunkelster Grauwert 0 (schwarz) … 255 (weiß)
    var darkest = 255
    var darkestRGB = (255, 255, 255)
    /// Breite in Punkten, die deutlich dunkel ist (Grauwert < 128)
    var solid = 0.0
    /// Breite in Punkten, die überhaupt sichtbar ist (Grauwert < 235)
    var visible = 0.0
    /// »Tintenmenge« quer zum Strich in Punkten (1 = 1 pt reines Schwarz)
    var cover = 0.0
    var pixels = ""
}

func measure(_ s: PKStroke, scale: CGFloat = 2, dark: Bool = false) -> Measure {
    let rect = CGRect(x: 0, y: 0, width: 40, height: 100)
    var m = Measure()
    guard let cg = render(PKDrawing(strokes: [s]), rect: rect, scale: scale, dark: dark) else {
        m.pixels = "kein Bild"
        return m
    }
    let w = cg.width, h = cg.height
    var buffer = [UInt8](repeating: 255, count: w * h * 4)
    buffer.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    let px = Double(w) / Double(rect.width)   // Pixel pro Punkt (tatsächlich)
    var rows = 0
    for y in stride(from: h / 2 - 20, through: h / 2 + 20, by: 4) {
        rows += 1
        var line = ""
        for x in 0..<w {
            let i = (y * w + x) * 4
            let r = Int(buffer[i]), g = Int(buffer[i + 1]), b = Int(buffer[i + 2])
            let lum = (299 * r + 587 * g + 114 * b) / 1000
            if lum < m.darkest { m.darkest = lum; m.darkestRGB = (r, g, b) }
            if lum < 128 { m.solid += 1 }
            if lum < 235 { m.visible += 1 }
            m.cover += Double(255 - lum) / 255
            if y == h / 2, lum < 250 { line += "\(lum) " }
        }
        if y == h / 2 { m.pixels = line }
    }
    m.solid /= Double(rows) * px
    m.visible /= Double(rows) * px
    m.cover /= Double(rows) * px
    return m
}

func f(_ v: Double) -> String { String(format: "%.2f", v) }
func f(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }

func report(_ c: Config, dark: Bool = false, color: PlatformColor = .black, label: String = "") {
    let s = stroke(c, color: color)
    let m = measure(s, dark: dark)
    print("\(c.name.padding(toLength: 11, withPad: " ", startingAt: 0)) size \(f(c.size)) force \(f(c.force)) v \(Int(c.speed)) alt \(Int(c.altitude * 180 / .pi)) op \(f(c.opacity))\(dark ? " DARK" : "")\(label)"
          + " | renderBounds.w \(f(s.renderBounds.width)) | schwarz-breite \(f(m.solid)) pt, sichtbar \(f(m.visible)) pt, tinte \(f(m.cover)) pt, dunkelster \(m.darkest) rgb\(m.darkestRGB) | mitte: \(m.pixels)")
}

#if canImport(UIKit)
print("Plattform: iOS \(UIDevice.current.systemVersion)")
#else
print("Plattform: macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
#endif

var inks: [(PKInk.InkType, String)] = [(.pen, "pen"), (.pencil, "pencil"), (.marker, "marker")]
if #available(iOS 17.0, macOS 14.0, *) {
    inks += [(.monoline, "monoline"), (.fountainPen, "fountainPen")]
    for (ink, name) in inks {
        print("Gültige Breite \(name): \(ink.validWidthRange), Standard \(ink.defaultWidth)")
    }
}

print("\n== Stift (.pen): Größe × Druck, Tempo 190 pt/s ==")
for size: CGFloat in [0.5, 1, 1.5, 1.7, 2, 2.2, 2.5, 3, 3.4, 4, 5, 6, 8] {
    for force: CGFloat in [0.25, 0.5, 1, 2, 4] {
        report(Config(ink: .pen, name: "pen", size: size, force: force))
    }
}

print("\n== Stift (.pen): Tempo und Winkel bei Größe 2 und 3.4 ==")
for size: CGFloat in [2, 3.4] {
    for speed in [0.0, 50, 190, 600, 2000] { report(Config(ink: .pen, name: "pen", size: size, speed: speed)) }
    for alt: CGFloat in [.pi / 2, .pi / 3, .pi / 4, .pi / 8] { report(Config(ink: .pen, name: "pen", size: size, altitude: alt)) }
    for op: CGFloat in [0.5, 1, 2] { report(Config(ink: .pen, name: "pen", size: size, opacity: op)) }
    for step: CGFloat in [0.3, 0.8, 2] { report(Config(ink: .pen, name: "pen", size: size, step: step), label: " step \(step)") }
}

if #available(iOS 17.0, macOS 14.0, *) {
    print("\n== Monoline und Füller ==")
    for size: CGFloat in [0.5, 1, 1.5, 1.7, 2, 2.2, 2.5, 3, 4] {
        for force: CGFloat in [0.5, 1, 4] {
            report(Config(ink: .monoline, name: "monoline", size: size, force: force))
        }
    }
    for size: CGFloat in [1, 2, 3, 4] {
        report(Config(ink: .fountainPen, name: "fountainPen", size: size))
    }
}

print("\n== Dunkelmodus (Schwarz wird dort evtl. umgefärbt) ==")
report(Config(ink: .pen, name: "pen", size: 2), dark: true)
report(Config(ink: .pen, name: "pen", size: 3.4), dark: true)
if #available(iOS 17.0, macOS 14.0, *) {
    report(Config(ink: .monoline, name: "monoline", size: 2), dark: true)
}
#if canImport(UIKit)
var resolved = UIColor.black
UITraitCollection(userInterfaceStyle: .dark).performAsCurrent { resolved = UIColor.label }
report(Config(ink: .pen, name: "pen", size: 2), color: resolved, label: " (Farbe = label im Dunkelmodus)")
report(Config(ink: .pen, name: "pen", size: 2), color: UIColor(white: 0, alpha: 1), label: " (Farbe = white 0)")
report(Config(ink: .pen, name: "pen", size: 2), color: UIColor(red: 0, green: 0, blue: 0, alpha: 1), label: " (Farbe = rgb 0)")
#endif
print("\nfertig")
