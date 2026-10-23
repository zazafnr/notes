import UIKit
import PencilKit

/// Macht aus gesetzten Handschrift-Strichen echte PencilKit-Striche (radierbar, auswählbar, wie selbst geschrieben).
enum HandwritingInk {
    /// Schreibtempo eines Stifts in Seitenpunkten pro Sekunde bei x-Höhe 12,5 (≈ 4 cm/s).
    static let baseSpeed: Double = 190

    /// Die KI schreibt immer mit schwarzem Kuli, unabhängig von der gewählten Stiftfarbe.
    static let color = UIColor.black

    /// Normaler Stift wie beim eigenen Schreiben (Monoline erschien auf dem iPad weiß statt schwarz).
    static let inkType: PKInkingTool.InkType = .pen

    /// Strichstärke wie der eigene Stift auf »Fein« (2 pt): dünn, aber sicher sichtbar.
    /// Darunter zeichnet PencilKit den Stift teils gar nicht mehr.
    static func pointSize(penWidth: CGFloat, xHeight: Double) -> CGFloat {
        2.2 * CGFloat(min(1.05, max(0.92, xHeight / 12.5)))
    }

    /// Tinte immer im hellen Modus anlegen, damit Schwarz nicht für den Dunkelmodus umgerechnet wird.
    static func makeInk(_ color: UIColor) -> PKInk {
        var ink = PKInk(inkType, color: color)
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = PKInk(inkType, color: color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
        }
        return ink
    }

    static func pkStroke(_ stroke: HWStroke, ink: PKInk, size: CGFloat, xHeight: Double, date: Date) -> PKStroke? {
        let points = resample(stroke.points, step: max(0.8, xHeight * 0.09))
        guard points.count >= 2 else {
            guard let p = stroke.points.first else { return nil }
            return pkStroke(HWStroke(points: [p, CGPoint(x: p.x + 0.4, y: p.y + 0.4)], weight: stroke.weight),
                            ink: ink, size: size, xHeight: xHeight, date: date)
        }
        let speed = baseSpeed * max(0.5, xHeight / 12.5)
        var distance: Double = 0
        var strokePoints: [PKStrokePoint] = []
        strokePoints.reserveCapacity(points.count)
        // Gleichmäßige Breite wie ein Kuli
        let w = size * CGFloat(stroke.weight)
        for (i, p) in points.enumerated() {
            if i > 0 { distance += hypot(Double(p.x - points[i - 1].x), Double(p.y - points[i - 1].y)) }
            // Voller Druck und volle Deckkraft: sattes Schwarz
            strokePoints.append(PKStrokePoint(location: p, timeOffset: distance / speed,
                                              size: CGSize(width: w, height: w), opacity: 1,
                                              force: 1, azimuth: 0, altitude: .pi / 2))
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: strokePoints, creationDate: date))
    }

    static func pkStrokes(_ strokes: [HWStroke], color: UIColor, size: CGFloat, xHeight: Double) -> [PKStroke] {
        let ink = HandwritingInk.makeInk(color)
        let date = Date()
        return strokes.compactMap { pkStroke($0, ink: ink, size: size, xHeight: xHeight, date: date) }
    }

    /// Gleichmäßig verteilte Punkte, damit die Kurve von PencilKit der Vorlage genau folgt.
    static func resample(_ points: [CGPoint], step: Double) -> [CGPoint] {
        guard points.count > 1 else { return points }
        var result = [points[0]]
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let d = hypot(Double(b.x - a.x), Double(b.y - a.y))
            let n = max(1, Int(ceil(d / step)))
            for k in 1...n {
                let t = CGFloat(k) / CGFloat(n)
                result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return result
    }

    static func length(_ points: [CGPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot(Double($1.1.x - $1.0.x), Double($1.1.y - $1.0.y)) }
    }

    /// Vorschaubild: Handschrift auf einem Stück Papier (für Einstellungen und Bestätigung).
    @MainActor
    static func previewImage(_ layout: HWLayout, paper: PaperStyle, size: CGSize, color: UIColor = .black,
                             penWidth: CGFloat = 4, xHeight: Double, scale: CGFloat = 2) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let strokes = pkStrokes(layout.strokes, color: color, size: pointSize(penWidth: penWidth, xHeight: xHeight), xHeight: xHeight)
        let drawing = PKDrawing(strokes: strokes)
        let rect = CGRect(origin: .zero, size: size)
        let inkImage = PageRenderer.ink(drawing, rect: rect, scale: scale)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            PageRenderer.drawPaper(paper, size: size, in: context.cgContext)
            inkImage.draw(in: rect)
        }
    }
}

/// Spielt Handschrift Strich für Strich ab, als würde gerade mit dem Apple Pencil geschrieben.
/// Fertige Wörter landen sofort als echte Striche in der Zeichnung.
@MainActor
final class HandwritingAnimator {
    private weak var host: PageCanvasHost?
    private let strokes: [HWStroke]
    private let pkStrokes: [PKStroke?]
    private let color: UIColor
    private let size: CGFloat
    private var starts: [Double] = []
    private var durations: [Double] = []
    private var committed = 0
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private let speed: Double
    private let preview = CAShapeLayer()
    private var undoBefore: PKDrawing?
    var onFinish: (() -> Void)?
    private(set) var isFinished = false

    var progress: Double {
        guard let last = starts.last, let lastDuration = durations.last else { return 1 }
        let total = last + lastDuration
        return total > 0 ? min(1, elapsed / total) : 1
    }

    private var elapsed: Double {
        guard startTime > 0 else { return 0 }
        return (CACurrentMediaTime() - startTime) * speed
    }

    init(strokes: [HWStroke], color: UIColor, size: CGFloat, xHeight: Double, speed: Double) {
        self.strokes = strokes
        self.color = color
        self.size = size
        self.speed = max(0.25, speed)
        let ink = HandwritingInk.makeInk(color)
        let date = Date()
        pkStrokes = strokes.map { HandwritingInk.pkStroke($0, ink: ink, size: size, xHeight: xHeight, date: date) }
        // Zeitplan: Strichlänge durch Tempo, dazwischen Stift absetzen und weiterführen
        let penSpeed = HandwritingInk.baseSpeed * max(0.5, xHeight / 12.5)
        var t = 0.0
        for (i, stroke) in strokes.enumerated() {
            if i > 0 {
                let prev = strokes[i - 1]
                let jump = hypot(Double((stroke.points.first?.x ?? 0) - (prev.points.last?.x ?? 0)),
                                 Double((stroke.points.first?.y ?? 0) - (prev.points.last?.y ?? 0)))
                t += 0.045 + jump / (penSpeed * 3.2) + (prev.endsWord ? 0.11 : 0)
            }
            starts.append(t)
            let d = max(0.035, HandwritingInk.length(stroke.points) / penSpeed)
            durations.append(d)
            t += d
        }
    }

    func start(on host: PageCanvasHost) {
        self.host = host
        undoBefore = host.canvas.drawing
        preview.fillColor = nil
        preview.strokeColor = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cgColor
        preview.lineWidth = size
        preview.lineCap = .round
        preview.lineJoin = .round
        host.writingLayer.layer.addSublayer(preview)
        host.isWriting = true
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Sofort fertig schreiben (Überspringen).
    func finishNow() {
        guard !isFinished else { return }
        commit(upTo: strokes.count)
        complete()
    }

    fileprivate func tick() {
        guard !isFinished, let host else {
            if !isFinished { complete() }
            return
        }
        let now = elapsed
        // Fertige Wörter übernehmen
        var lastDone = committed
        var i = committed
        while i < strokes.count, starts[i] + durations[i] <= now {
            if strokes[i].endsWord || i == strokes.count - 1 { lastDone = i + 1 }
            i += 1
        }
        if lastDone > committed { commit(upTo: lastDone) }
        if committed >= strokes.count {
            complete()
            return
        }
        // Angefangene Striche als Vorschau zeichnen
        let path = UIBezierPath()
        var tip: CGPoint?
        var j = committed
        while j < strokes.count, starts[j] <= now {
            let fraction = min(1, (now - starts[j]) / durations[j])
            let points = partial(strokes[j].points, fraction: fraction)
            if let first = points.first {
                path.move(to: first)
                points.dropFirst().forEach { path.addLine(to: $0) }
                if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.3, y: first.y)) }
                tip = points.last
            }
            j += 1
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.path = path.cgPath
        CATransaction.commit()
        if let tip { host.follow(pagePoint: tip) }
    }

    private func partial(_ points: [CGPoint], fraction: Double) -> [CGPoint] {
        guard fraction < 1, points.count > 1 else { return points }
        let target = HandwritingInk.length(points) * fraction
        var walked = 0.0
        var result = [points[0]]
        for k in 1..<points.count {
            let a = points[k - 1], b = points[k]
            let d = hypot(Double(b.x - a.x), Double(b.y - a.y))
            if walked + d >= target {
                let t = d > 0 ? CGFloat((target - walked) / d) : 0
                result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                return result
            }
            walked += d
            result.append(b)
        }
        return result
    }

    private func commit(upTo end: Int) {
        guard let host, end > committed else { return }
        host.appendStrokes(pkStrokes[committed..<end].compactMap { $0 })
        committed = end
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.path = nil
        CATransaction.commit()
    }

    private func complete() {
        guard !isFinished else { return }
        isFinished = true
        link?.invalidate()
        link = nil
        preview.removeFromSuperlayer()
        if let host {
            host.isWriting = false
            if let before = undoBefore { host.registerReplaceUndo(before: before, after: host.canvas.drawing) }
        }
        onFinish?()
    }
}

/// CADisplayLink hält sein Ziel fest; der Umweg verhindert einen Speicher-Kreislauf.
private final class DisplayLinkProxy: NSObject {
    weak var target: HandwritingAnimator?

    init(_ target: HandwritingAnimator) { self.target = target }

    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            guard let target else {
                link.invalidate()
                return
            }
            target.tick()
        }
    }
}
