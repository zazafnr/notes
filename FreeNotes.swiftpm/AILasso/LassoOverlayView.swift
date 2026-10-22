import UIKit

/// Durchsichtige Ebene über der Seite. Im KI-Modus zieht man hier eine leuchtende Schleife.
final class LassoOverlayView: UIView {
    var onComplete: ((UIBezierPath) -> Void)?

    private var points: [CGPoint] = []
    private let fillLayer = CAShapeLayer()
    private let glowLayer = CAShapeLayer()
    private let strokeMask = CAShapeLayer()
    private let gradientLayer = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false

        fillLayer.fillColor = Theme.aiUIColors[1].withAlphaComponent(0.08).cgColor
        fillLayer.strokeColor = nil

        glowLayer.fillColor = nil
        glowLayer.strokeColor = Theme.aiUIColors[1].withAlphaComponent(0.45).cgColor
        glowLayer.lineWidth = 12
        glowLayer.lineCap = .round
        glowLayer.lineJoin = .round
        glowLayer.shadowColor = Theme.aiUIColors[1].cgColor
        glowLayer.shadowOpacity = 0.9
        glowLayer.shadowRadius = 14
        glowLayer.shadowOffset = .zero

        strokeMask.fillColor = nil
        strokeMask.strokeColor = UIColor.black.cgColor
        strokeMask.lineWidth = 4.5
        strokeMask.lineCap = .round
        strokeMask.lineJoin = .round

        gradientLayer.colors = Theme.aiUIColors.map(\.cgColor)
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        gradientLayer.mask = strokeMask

        layer.addSublayer(fillLayer)
        layer.addSublayer(glowLayer)
        layer.addSublayer(gradientLayer)
        startShimmer()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
        strokeMask.frame = bounds
    }

    /// Der Farbverlauf wandert langsam, damit die Schleife „lebt“.
    private func startShimmer() {
        let start = CABasicAnimation(keyPath: "startPoint")
        start.fromValue = CGPoint(x: 0, y: 0)
        start.toValue = CGPoint(x: 1, y: 0)
        let end = CABasicAnimation(keyPath: "endPoint")
        end.fromValue = CGPoint(x: 1, y: 1)
        end.toValue = CGPoint(x: 0, y: 1)
        let group = CAAnimationGroup()
        group.animations = [start, end]
        group.duration = 1.6
        group.autoreverses = true
        group.repeatCount = .infinity
        gradientLayer.add(group, forKey: "shimmer")
    }

    private func updatePath(closed: Bool) {
        let path = UIBezierPath()
        guard let first = points.first else {
            [fillLayer, glowLayer, strokeMask].forEach { $0.path = nil }
            return
        }
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        if closed { path.close() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.path = path.cgPath
        strokeMask.path = path.cgPath
        fillLayer.path = closed ? path.cgPath : nil
        CATransaction.commit()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        layer.removeAllAnimations()
        alpha = 1
        points = [touch.location(in: self)]
        updatePath(closed: false)
        Haptics.soft()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        points.append(contentsOf: samples.map { $0.location(in: self) })
        updatePath(closed: false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        updatePath(closed: true)
        let path = UIBezierPath()
        if let first = points.first {
            path.move(to: first)
            for p in points.dropFirst() { path.addLine(to: p) }
            path.close()
        }
        let box = path.bounds
        if points.count > 4, box.width > 24, box.height > 24 {
            onComplete?(path)
        }
        fadeOut()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        fadeOut()
    }

    func reset() {
        points = []
        updatePath(closed: false)
        alpha = 1
    }

    private func fadeOut() {
        UIView.animate(withDuration: 0.45, delay: 0.35, options: [.curveEaseOut]) {
            self.alpha = 0
        } completion: { _ in
            self.reset()
        }
    }
}
