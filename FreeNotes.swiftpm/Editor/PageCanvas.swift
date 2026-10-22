import SwiftUI
import PencilKit

// MARK: - Papier (gekachelt, bleibt bei jedem Zoom scharf)

/// Papiermuster als gekachelte Ebene: Beim Hineinzoomen werden die Linien in höherer Auflösung neu gezeichnet.
final class PaperPatternLayer: CATiledLayer {
    private let lock = NSLock()
    private var paperStyle: PaperStyle = .blank
    private var paperSize: CGSize = .zero

    override class func fadeDuration() -> CFTimeInterval { 0.05 }

    func update(style: PaperStyle, size: CGSize) {
        lock.lock()
        let changed = style != paperStyle || size != paperSize
        paperStyle = style
        paperSize = size
        lock.unlock()
        if changed { setNeedsDisplay() }
    }

    override func draw(in ctx: CGContext) {
        lock.lock()
        let style = paperStyle
        let size = paperSize
        lock.unlock()
        PageRenderer.drawPaper(style, size: size, in: ctx)
    }
}

/// Scans und eingefügte Bilder, ebenfalls gekachelt.
final class PageContentLayer: CATiledLayer {
    private let lock = NSLock()
    private var page: Page?
    private var images: [String: UIImage] = [:]

    override class func fadeDuration() -> CFTimeInterval { 0.05 }

    func update(page: Page, images: [String: UIImage]) {
        lock.lock()
        self.page = page
        self.images = images
        lock.unlock()
        setNeedsDisplay()
    }

    override func draw(in ctx: CGContext) {
        lock.lock()
        let page = self.page
        let images = self.images
        lock.unlock()
        guard let page else { return }
        UIGraphicsPushContext(ctx)
        PageRenderer.drawImages(page: page, image: { images[$0] }, in: ctx)
        UIGraphicsPopContext()
    }
}

/// Papier, Scans und Bilder. Liegt hinter der Tinte und wird beim Zoomen mit skaliert.
final class PaperBackgroundView: UIView {
    private let patternLayer = PaperPatternLayer()
    private let contentLayer = PageContentLayer()
    let imageProvider: (String) -> UIImage?

    var page: Page { didSet { if oldValue != page { apply() } } }

    init(page: Page, imageProvider: @escaping (String) -> UIImage?) {
        self.page = page
        self.imageProvider = imageProvider
        super.init(frame: CGRect(origin: .zero, size: page.size))
        backgroundColor = .white
        isUserInteractionEnabled = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 3)
        for tiled in [patternLayer, contentLayer] as [CATiledLayer] {
            tiled.contentsScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
            tiled.levelsOfDetail = 6
            tiled.levelsOfDetailBias = 5
            tiled.tileSize = CGSize(width: 512, height: 512)
            layer.addSublayer(tiled)
        }
        contentLayer.isOpaque = false
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        patternLayer.frame = bounds
        contentLayer.frame = bounds
        CATransaction.commit()
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
    }

    private func apply() {
        patternLayer.update(style: page.paper, size: page.size)
        var images: [String: UIImage] = [:]
        for name in [page.background].compactMap({ $0 }) + page.items.map(\.asset) {
            images[name] = imageProvider(name)
        }
        contentLayer.update(page: page, images: images)
    }
}

// MARK: - Seite mit Zeichenfläche

/// Enthält die PencilKit-Zeichenfläche, das Papier, die Bild-Griffe, Geometrie-Werkzeuge und die KI-Schleife.
final class PageCanvasHost: UIView, PKCanvasViewDelegate, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
    let canvas = PKCanvasView()
    let paper: PaperBackgroundView
    let imageOverlay = ImageEditOverlay()
    let geometry = GeometryOverlayView()
    let lasso = LassoOverlayView()
    /// Ebene über der Tinte für Handschrift, die gerade »geschrieben« wird (Seitenkoordinaten).
    let writingLayer = UIView()
    private(set) var page: Page

    var flipDirection: FlipDirection = .horizontal
    var onDrawingChange: ((PKDrawing) -> Void)?
    var onLasso: ((CGRect, PKDrawing) -> Void)?
    var onPencilAction: (() -> Void)?
    var onItemsChange: (([PageImageItem]) -> Void)?
    var onFlip: ((Int) -> Void)?
    var onImageTap: (() -> Void)?
    var onEmptyTap: (() -> Void)?

    private var didInitialLayout = false
    /// Platz für die Werkzeugleiste oben und zum Weiterscrollen unten; seitlich kein Rand.
    private let insets = UIEdgeInsets(top: 72, left: 0, bottom: 120, right: 0)
    /// Breite füllen (Standard) oder ganze Seite sichtbar.
    private var fitsWholePage = false
    private var swipes: [UISwipeGestureRecognizer] = []
    private var imageTap: UITapGestureRecognizer?
    private var pencilExitTap: UITapGestureRecognizer?

    var aiMode = false {
        didSet {
            guard aiMode != oldValue else { return }
            lasso.isHidden = !aiMode
            lasso.reset()
            updateInteraction()
        }
    }

    var imageEditMode = false {
        didSet {
            guard imageEditMode != oldValue else { return }
            imageOverlay.isHidden = !imageEditMode
            imageOverlay.setItems(page.items)
            imageOverlay.layoutHandles()
            updateInteraction()
        }
    }

    var geometryTool: GeometryTool? {
        didSet {
            guard geometryTool != oldValue else { return }
            geometry.tool = geometryTool ?? .compass
            geometry.isHidden = geometryTool == nil
            geometry.reset()
            updateInteraction()
        }
    }

    var fingerDrawing = false {
        didSet {
            canvas.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
            updateInteraction()
        }
    }

    init(page: Page, drawing: PKDrawing, imageProvider: @escaping (String) -> UIImage?) {
        self.page = page
        paper = PaperBackgroundView(page: page, imageProvider: imageProvider)
        super.init(frame: .zero)
        backgroundColor = .clear

        canvas.drawing = drawing
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.drawingPolicy = .pencilOnly
        canvas.alwaysBounceVertical = true
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.contentInset = insets
        canvas.delegate = self
        canvas.insertSubview(paper, at: 0)
        writingLayer.isUserInteractionEnabled = false
        writingLayer.backgroundColor = .clear
        canvas.addSubview(writingLayer)
        addSubview(canvas)

        imageOverlay.paper = paper
        imageOverlay.isHidden = true
        imageOverlay.onChange = { [weak self] items, final in self?.itemsChanged(items, final: final) }
        addSubview(imageOverlay)

        geometry.paper = paper
        geometry.isHidden = true
        geometry.onComplete = { [weak self] tool, a, b in self?.addGeometry(tool, from: a, to: b) }
        addSubview(geometry)

        lasso.isHidden = true
        lasso.onComplete = { [weak self] path in self?.handleLasso(path) }
        addSubview(lasso)

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)

        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipe.direction = direction
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            swipe.delegate = self
            canvas.addGestureRecognizer(swipe)
            swipes.append(swipe)
        }

        // Bild mit dem Finger antippen → Bearbeiten (verschieben, skalieren, drehen)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        tap.cancelsTouchesInView = false
        tap.delegate = self
        canvas.addGestureRecognizer(tap)
        imageTap = tap

        // Im Bild-Modus beendet auch ein Pencil-Tipp neben die Bilder die Bearbeitung
        let pencilTap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        pencilTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pencilTap.cancelsTouchesInView = false
        pencilTap.delegate = self
        pencilTap.isEnabled = false
        canvas.addGestureRecognizer(pencilTap)
        pencilExitTap = pencilTap
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(page newPage: Page) {
        guard newPage != page else { return }
        let sizeChanged = newPage.size != page.size
        page = newPage
        paper.page = newPage
        if !imageOverlay.isDragging {
            imageOverlay.setItems(newPage.items)
            imageOverlay.layoutHandles()
        }
        if sizeChanged {
            didInitialLayout = false
            setNeedsLayout()
        }
    }

    /// Während die Handschrift vorgeschrieben wird, ist die Seite gesperrt.
    var isWriting = false {
        didSet {
            guard isWriting != oldValue else { return }
            updateInteraction()
        }
    }

    private func updateInteraction() {
        let overlayActive = imageEditMode || geometryTool != nil
        canvas.drawingGestureRecognizer.isEnabled = !imageEditMode && !isWriting
        swipes.forEach { $0.isEnabled = !fingerDrawing && !aiMode && !overlayActive && !isWriting }
        imageTap?.isEnabled = !aiMode && geometryTool == nil
        pencilExitTap?.isEnabled = imageEditMode
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        imageOverlay.frame = bounds
        geometry.frame = bounds
        lasso.frame = bounds
        guard bounds.width > 100 else { return }

        let widthFit = widthFitScale
        let wasAtWidthFit = abs(canvas.zoomScale - lastWidthFit) < 0.001
        let wasAtPageFit = abs(canvas.zoomScale - canvas.minimumZoomScale) < 0.001 && fitsWholePage
        canvas.minimumZoomScale = min(widthFit, pageFitScale)
        canvas.maximumZoomScale = widthFit * 6
        if !didInitialLayout || wasAtWidthFit {
            canvas.zoomScale = fitsWholePage ? pageFitScale : widthFit
        } else if wasAtPageFit {
            canvas.zoomScale = pageFitScale
        }
        lastWidthFit = widthFit
        updateForZoom()
        if !didInitialLayout {
            canvas.contentOffset = CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top)
            didInitialLayout = true
        }
        imageOverlay.layoutHandles()
        startCurlIfReady()
    }

    private var lastWidthFit: CGFloat = 0

    /// Zoom, bei dem die Seite genau die Breite füllt.
    private var widthFitScale: CGFloat {
        max(bounds.width - insets.left - insets.right, 1) / CGFloat(page.width)
    }

    /// Zoom, bei dem die ganze Seite auf den Bildschirm passt (auch im Querformat).
    private var pageFitScale: CGFloat {
        let h = max(bounds.height - insets.top - 16, 1) / CGFloat(page.height)
        return min(h, widthFitScale)
    }

    var wholePageMode: Bool { fitsWholePage }

    /// Zwischen »Breite füllen« und »ganze Seite« wechseln.
    func setWholePage(_ on: Bool, animated: Bool) {
        fitsWholePage = on
        guard didInitialLayout else { return }
        let target = on ? pageFitScale : widthFitScale
        if animated {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
                self.applyZoom(target)
            }
        } else {
            applyZoom(target)
        }
    }

    private func applyZoom(_ target: CGFloat) {
        canvas.zoomScale = target
        updateForZoom()
        canvas.contentOffset = CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top)
    }

    private func updateForZoom() {
        let z = canvas.zoomScale
        let size = CGSize(width: CGFloat(page.width) * z, height: CGFloat(page.height) * z)
        // Kleiner als der Bildschirm: Seite mittig halten
        let side = max((bounds.width - size.width) / 2, insets.left)
        let free = bounds.height - size.height - insets.top - insets.bottom
        let extra = max(free / 2, 0)
        let newInsets = UIEdgeInsets(top: insets.top + extra, left: side, bottom: insets.bottom + extra, right: side)
        if canvas.contentInset != newInsets { canvas.contentInset = newInsets }
        canvas.contentSize = size
        paper.bounds = CGRect(origin: .zero, size: page.size)
        paper.transform = CGAffineTransform(scaleX: z, y: z)
        paper.center = CGPoint(x: size.width / 2, y: size.height / 2)
        writingLayer.bounds = paper.bounds
        writingLayer.transform = paper.transform
        writingLayer.center = paper.center
        if writingLayer.superview === canvas, canvas.subviews.last !== writingLayer {
            canvas.bringSubviewToFront(writingLayer)
        }
    }

    // MARK: Blättern

    private var pendingCurl: (view: UIView, forward: Bool)?

    /// Blättern wie in GoodNotes: Die alte Seite gleitet zur Seite hinaus, die neue schiebt sich hinterher.
    func playCurl(_ snapshot: UIView, forward: Bool) {
        pendingCurl = (snapshot, forward)
        setNeedsLayout()
    }

    private func startCurlIfReady() {
        guard let curl = pendingCurl, bounds.width > 100 else { return }
        pendingCurl = nil
        let snap = curl.view
        snap.frame = bounds
        snap.isUserInteractionEnabled = false
        addSubview(snap)
        // Kleiner Abstand zwischen den Seiten, wie beim Durchblättern eines Hefts
        let vertical = flipDirection == .vertical
        let distance = (vertical ? bounds.height : bounds.width) + 24
        let sign: CGFloat = curl.forward ? 1 : -1
        func shift(_ amount: CGFloat) -> CGAffineTransform {
            vertical ? CGAffineTransform(translationX: 0, y: amount) : CGAffineTransform(translationX: amount, y: 0)
        }
        canvas.transform = shift(sign * distance)
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0.2,
                       options: [.allowUserInteraction, .curveEaseOut]) {
            snap.transform = shift(-sign * distance)
            self.canvas.transform = .identity
        } completion: { _ in
            snap.removeFromSuperview()
            self.canvas.transform = .identity
        }
    }

    // MARK: Handschrift vorschreiben

    /// Hängt fertige Striche an (wie selbst geschrieben, wird gespeichert).
    func appendStrokes(_ strokes: [PKStroke]) {
        guard !strokes.isEmpty else { return }
        var drawing = canvas.drawing
        drawing.strokes.append(contentsOf: strokes)
        canvas.drawing = drawing
        onDrawingChange?(drawing)
    }

    /// Ein einziger Rückgängig-Schritt für den ganzen geschriebenen Text.
    func registerReplaceUndo(before: PKDrawing, after: PKDrawing) {
        canvas.undoManager?.registerUndo(withTarget: self) { host in
            MainActor.assumeIsolated {
                host.canvas.drawing = before
                host.onDrawingChange?(before)
                host.registerReplaceUndo(before: after, after: before)
            }
        }
    }

    /// Scrollt mit, damit die Stiftspitze beim Schreiben sichtbar bleibt.
    func follow(pagePoint: CGPoint) {
        let z = canvas.zoomScale
        let p = CGPoint(x: pagePoint.x * z, y: pagePoint.y * z)
        var offset = canvas.contentOffset
        let visibleTop = offset.y + insets.top + 40
        let visibleBottom = offset.y + canvas.bounds.height - insets.bottom - 40
        var target = offset
        if p.y > visibleBottom || p.y < visibleTop {
            target.y = p.y - canvas.bounds.height * 0.45
        }
        let visibleLeft = offset.x + 30
        let visibleRight = offset.x + canvas.bounds.width - 30
        if p.x > visibleRight || p.x < visibleLeft {
            target.x = p.x - canvas.bounds.width * 0.5
        }
        let minY = -canvas.contentInset.top
        let maxY = max(minY, canvas.contentSize.height - canvas.bounds.height + canvas.contentInset.bottom)
        let minX = -canvas.contentInset.left
        let maxX = max(minX, canvas.contentSize.width - canvas.bounds.width + canvas.contentInset.right)
        target.x = min(max(target.x, minX), maxX)
        target.y = min(max(target.y, minY), maxY)
        guard target != offset else { return }
        // Weich hinterhergleiten statt springen
        offset.x += (target.x - offset.x) * 0.12
        offset.y += (target.y - offset.y) * 0.12
        canvas.contentOffset = offset
    }

    // MARK: Scrollen & Zeichnen

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateForZoom()
        imageOverlay.layoutHandles()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        imageOverlay.layoutHandles()
    }

    /// Senkrechtes Blättern: über das Seitenende hinaus ziehen.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard flipDirection == .vertical, !aiMode, !imageEditMode, geometryTool == nil, !isWriting else { return }
        let y = scrollView.contentOffset.y
        let maxY = scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom
        if y > maxY + 90 {
            onFlip?(1)
        } else if y < -scrollView.contentInset.top - 90 {
            onFlip?(-1)
        }
    }

    @objc private func handleSwipe(_ swipe: UISwipeGestureRecognizer) {
        guard flipDirection == .horizontal, !isWriting,
              canvas.zoomScale <= widthFitScale + 0.01 else { return }
        onFlip?(swipe.direction == .left ? 1 : -1)
    }

    @objc private func handleTap(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: paper)
        if page.items.contains(where: { $0.contains(point) }) {
            onImageTap?()
        } else if imageEditMode {
            // Daneben getippt: Bearbeiten beenden
            onEmptyTap?()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        onDrawingChange?(canvasView.drawing)
    }

    // MARK: Lineal

    var rulerActive: Bool {
        get { canvas.isRulerActive }
        set { canvas.isRulerActive = newValue }
    }

    // MARK: Zirkel & Strecke

    /// Fügt einen exakten Kreis oder eine gerade Strecke als echten Stift-Strich ein (rückgängig machbar).
    private func addGeometry(_ tool: GeometryTool, from a: CGPoint, to b: CGPoint) {
        let inking = (canvas.tool as? PKInkingTool) ?? PKInkingTool(.pen, color: .black, width: 3)
        let ink = PKInk(inking.inkType, color: inking.color)
        let width = max(inking.width, 1.5)
        var points: [CGPoint] = []
        switch tool {
        case .compass:
            let r = hypot(b.x - a.x, b.y - a.y)
            let start = atan2(b.y - a.y, b.x - a.x)
            let n = max(72, Int(r / 2))
            points = (0...n).map { i in
                let t = start + CGFloat(i) / CGFloat(n) * 2 * .pi
                return CGPoint(x: a.x + r * cos(t), y: a.y + r * sin(t))
            }
        case .line:
            let n = 24
            points = (0...n).map { i in
                let t = CGFloat(i) / CGFloat(n)
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
        }
        let strokePoints = points.enumerated().map { index, p in
            PKStrokePoint(location: p, timeOffset: TimeInterval(index) * 0.004,
                          size: CGSize(width: width, height: width), opacity: 1, force: 1,
                          azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: ink, path: PKStrokePath(controlPoints: strokePoints, creationDate: Date()))
        let before = canvas.drawing
        var after = before
        after.strokes.append(stroke)
        canvas.undoManager?.registerUndo(withTarget: canvas) { canvas in
            MainActor.assumeIsolated { canvas.drawing = before }
        }
        canvas.drawing = after
        onDrawingChange?(after)
        Haptics.success()
    }

    // MARK: Bilder bearbeiten

    private func itemsChanged(_ items: [PageImageItem], final: Bool) {
        var updated = page
        updated.items = items
        paper.page = updated
        if final {
            page = updated
            onItemsChange?(items)
        }
    }

    // MARK: KI-Schleife

    private func handleLasso(_ path: UIBezierPath) {
        let inPage = lasso.convert(path.bounds, to: paper)
        let rect = inPage.insetBy(dx: -16, dy: -16).intersection(page.bounds).integral
        guard !rect.isNull, rect.width > 10, rect.height > 10 else { return }
        onLasso?(rect, canvas.drawing)
    }

    // MARK: Apple Pencil (Doppeltippen / Drücken)

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        onPencilAction?()
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        if squeeze.phase == .ended {
            onPencilAction?()
        }
    }
}

// MARK: - Geometrie: Zirkel und Strecke

enum GeometryTool: String, CaseIterable, Identifiable {
    case compass, line

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compass: return "Zirkel"
        case .line: return "Strecke"
        }
    }

    var symbol: String {
        switch self {
        case .compass: return "compass.drawing"
        case .line: return "line.diagonal"
        }
    }

    var hint: String {
        switch self {
        case .compass: return "Zirkel: auf den Mittelpunkt setzen und den Radius aufziehen"
        case .line: return "Strecke: Anfangspunkt setzen und ziehen (rastet bei 0°, 45°, 90° ein)"
        }
    }
}

/// Zeigt beim Ziehen eine Vorschau mit Maßen in cm und meldet am Ende Start und Ende in Seitenkoordinaten.
final class GeometryOverlayView: UIView {
    weak var paper: UIView?
    var tool: GeometryTool = .compass
    var onComplete: ((GeometryTool, CGPoint, CGPoint) -> Void)?

    private let shape = CAShapeLayer()
    private let guide = CAShapeLayer()
    private let centerDot = CAShapeLayer()
    private let label = PaddedLabel()
    private var start: CGPoint?
    private var end: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false

        shape.fillColor = nil
        shape.strokeColor = UIColor.systemIndigo.cgColor
        shape.lineWidth = 2.5
        guide.fillColor = nil
        guide.strokeColor = UIColor.systemIndigo.withAlphaComponent(0.6).cgColor
        guide.lineWidth = 1.5
        guide.lineDashPattern = [6, 5]
        centerDot.fillColor = UIColor.systemIndigo.cgColor
        [guide, shape, centerDot].forEach { layer.addSublayer($0) }

        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor.systemIndigo
        label.layer.cornerRadius = 12
        label.layer.masksToBounds = true
        label.isHidden = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reset() {
        start = nil
        end = nil
        [shape, guide, centerDot].forEach { $0.path = nil }
        label.isHidden = true
    }

    private var zoom: CGFloat { max(paper?.transform.a ?? 1, 0.01) }

    /// Rastet Länge auf 1 mm und bei der Strecke den Winkel auf 0°/45°/90°… ein.
    private func snapped(_ a: CGPoint, _ b: CGPoint) -> (end: CGPoint, lengthCM: CGFloat, degrees: CGFloat) {
        var angle = atan2(b.y - a.y, b.x - a.x)
        if tool == .line {
            let step = CGFloat.pi / 4
            let nearest = (angle / step).rounded() * step
            if abs(angle - nearest) < 3 * .pi / 180 { angle = nearest }
        }
        let pagePoints = hypot(b.x - a.x, b.y - a.y) / zoom
        let cm = (PageMetrics.centimeters(pagePoints) * 10).rounded() / 10
        let length = cm * PageMetrics.pointsPerCentimeter * zoom
        let snappedEnd = CGPoint(x: a.x + length * cos(angle), y: a.y + length * sin(angle))
        var degrees = -angle * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return (snappedEnd, cm, degrees)
    }

    private func redraw() {
        guard let a = start else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        centerDot.path = UIBezierPath(ovalIn: CGRect(x: a.x - 4, y: a.y - 4, width: 8, height: 8)).cgPath
        guard let b = end else {
            CATransaction.commit()
            return
        }
        let s = snapped(a, b)
        let line = UIBezierPath()
        line.move(to: a)
        line.addLine(to: s.end)
        switch tool {
        case .compass:
            let r = hypot(s.end.x - a.x, s.end.y - a.y)
            shape.path = UIBezierPath(ovalIn: CGRect(x: a.x - r, y: a.y - r, width: 2 * r, height: 2 * r)).cgPath
            guide.path = line.cgPath
            label.text = "r = \(format(s.lengthCM)) cm"
        case .line:
            shape.path = line.cgPath
            guide.path = nil
            label.text = "\(format(s.lengthCM)) cm · \(Int(s.degrees.rounded()))°"
        }
        CATransaction.commit()
        label.isHidden = false
        label.sizeToFit()
        label.center = CGPoint(x: (a.x + s.end.x) / 2, y: min(a.y, s.end.y) - 28)
    }

    private func format(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value)).replacingOccurrences(of: ".", with: ",")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        start = t.location(in: self)
        end = nil
        redraw()
        Haptics.soft()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        end = t.location(in: self)
        redraw()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { reset() }
        guard let a = start, let b = end, let paper else { return }
        let s = snapped(a, b)
        guard s.lengthCM >= 0.2 else { return }
        onComplete?(tool, convert(a, to: paper), convert(s.end, to: paper))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        reset()
    }
}

final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.insetBy(dx: 10, dy: 4))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let s = super.sizeThatFits(size)
        return CGSize(width: s.width + 20, height: s.height + 8)
    }
}

// MARK: - Griffe zum Verschieben, Skalieren und Drehen von Bildern

final class ImageEditOverlay: UIView {
    weak var paper: UIView?
    var onChange: (([PageImageItem], Bool) -> Void)?
    private(set) var isDragging = false

    private var items: [PageImageItem] = []
    private var handles: [UUID: ImageHandleView] = [:]
    private var startItem: PageImageItem?
    private var startDistance: CGFloat = 1
    private var startAngle: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Berührungen außerhalb der Griffe gehen an die Seite darunter (Scrollen, Zoomen).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view === self ? nil : view
    }

    func setItems(_ newItems: [PageImageItem]) {
        items = newItems
        let ids = Set(newItems.map(\.id))
        for (id, handle) in handles where !ids.contains(id) {
            handle.removeFromSuperview()
            handles[id] = nil
        }
        for item in newItems where handles[item.id] == nil {
            let handle = ImageHandleView()
            let id = item.id
            handle.onMove = { [weak self] d, state in self?.move(id, delta: d, state: state) }
            handle.onPinch = { [weak self] factor, state in self?.pinch(id, factor: factor, state: state) }
            handle.onRotate = { [weak self] radians, state in self?.rotate(id, by: radians, state: state) }
            handle.onResizeKnob = { [weak self] location, state in self?.resizeKnob(id, location: location, state: state) }
            handle.onRotateKnob = { [weak self] location, state in self?.rotateKnob(id, location: location, state: state) }
            handle.onAction = { [weak self] action in self?.perform(action, on: id) }
            addSubview(handle)
            handles[id] = handle
        }
        // Reihenfolge der Griffe wie die Bilder (oberstes Bild zuletzt)
        for item in newItems { if let h = handles[item.id] { bringSubviewToFront(h) } }
    }

    func layoutHandles() {
        guard let paper, !isHidden else { return }
        let z = max(paper.transform.a, 0.01)
        for item in items {
            guard let h = handles[item.id] else { continue }
            h.transform = .identity
            h.bounds = CGRect(x: 0, y: 0, width: item.frame.width * z, height: item.frame.height * z)
            h.center = paper.convert(item.center, to: self)
            h.transform = CGAffineTransform(rotationAngle: item.angle)
        }
    }

    private var zoom: CGFloat { max(paper?.transform.a ?? 1, 0.01) }
    private var pageBounds: CGRect { paper?.bounds ?? .zero }

    private func index(of id: UUID, state: UIGestureRecognizer.State) -> Int? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        if state == .began {
            startItem = items[i]
            isDragging = true
            Haptics.tap()
        }
        return i
    }

    private func finish(_ state: UIGestureRecognizer.State) {
        layoutHandles()
        let final = state == .ended || state == .cancelled || state == .failed
        if final {
            isDragging = false
        }
        onChange?(items, final)
    }

    private func setSize(_ i: Int, width: CGFloat) {
        let f = items[i].frame
        guard f.width > 0 else { return }
        let aspect = f.height / f.width
        let w = min(max(width, 40), pageBounds.width * 1.5)
        let c = items[i].center
        items[i].frame = CGRect(x: c.x - w / 2, y: c.y - w * aspect / 2, width: w, height: w * aspect)
    }

    /// Rastet bei 0°, 90°, 180°, 270° ein.
    private func snapAngle(_ angle: CGFloat) -> CGFloat {
        let step = CGFloat.pi / 2
        let nearest = (angle / step).rounded() * step
        return abs(angle - nearest) < 4 * .pi / 180 ? nearest : angle
    }

    private func isFinal(_ state: UIGestureRecognizer.State) -> Bool {
        state == .ended || state == .cancelled || state == .failed
    }

    // Verschieben, Zwei-Finger-Zoomen und -Drehen kommen gleichzeitig und als Schritte.
    private func move(_ id: UUID, delta: CGPoint, state: UIGestureRecognizer.State) {
        guard let i = index(of: id, state: state) else { return }
        var f = items[i].frame
        f.origin.x += delta.x / zoom
        f.origin.y += delta.y / zoom
        f.origin.x = min(max(f.origin.x, -f.width * 0.5), pageBounds.width - f.width * 0.5)
        f.origin.y = min(max(f.origin.y, -f.height * 0.5), pageBounds.height - f.height * 0.5)
        items[i].frame = f
        finish(state)
    }

    private func pinch(_ id: UUID, factor: CGFloat, state: UIGestureRecognizer.State) {
        guard let i = index(of: id, state: state) else { return }
        setSize(i, width: items[i].frame.width * factor)
        finish(state)
    }

    private func rotate(_ id: UUID, by delta: CGFloat, state: UIGestureRecognizer.State) {
        guard let i = index(of: id, state: state) else { return }
        var angle = items[i].angle + delta
        if isFinal(state) { angle = snapAngle(angle) }
        items[i].rotation = Double(angle)
        finish(state)
    }

    private func resizeKnob(_ id: UUID, location: CGPoint, state: UIGestureRecognizer.State) {
        guard let i = index(of: id, state: state), let start = startItem, let paper else { return }
        let c = paper.convert(start.center, to: self)
        let d = hypot(location.x - c.x, location.y - c.y)
        if state == .began { startDistance = max(d, 1) }
        setSize(i, width: start.frame.width * d / startDistance)
        finish(state)
    }

    private func rotateKnob(_ id: UUID, location: CGPoint, state: UIGestureRecognizer.State) {
        guard let i = index(of: id, state: state), let start = startItem, let paper else { return }
        let c = paper.convert(start.center, to: self)
        let a = atan2(location.y - c.y, location.x - c.x)
        if state == .began { startAngle = a }
        items[i].rotation = Double(snapAngle(start.angle + a - startAngle))
        finish(state)
    }

    private func perform(_ action: ImageHandleView.Action, on id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        switch action {
        case .duplicate:
            var copy = items[i]
            copy.id = UUID()
            copy.frame = copy.frame.offsetBy(dx: 30, dy: 30)
            items.append(copy)
        case .front:
            items.append(items.remove(at: i))
        case .back:
            items.insert(items.remove(at: i), at: 0)
        case .resetRotation:
            items[i].rotation = nil
        case .delete:
            items.remove(at: i)
        }
        setItems(items)
        layoutHandles()
        Haptics.success()
        onChange?(items, true)
    }
}

final class ImageHandleView: UIView, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
    enum Action { case duplicate, front, back, resetRotation, delete }

    var onMove: ((CGPoint, UIGestureRecognizer.State) -> Void)?
    var onPinch: ((CGFloat, UIGestureRecognizer.State) -> Void)?
    var onRotate: ((CGFloat, UIGestureRecognizer.State) -> Void)?
    var onResizeKnob: ((CGPoint, UIGestureRecognizer.State) -> Void)?
    var onRotateKnob: ((CGPoint, UIGestureRecognizer.State) -> Void)?
    var onAction: ((Action) -> Void)?

    private let border = CAShapeLayer()
    private let resizeKnob = UIView()
    private let rotateKnob = UIImageView()
    private let rotateStem = UIView()
    private let deleteButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemIndigo.withAlphaComponent(0.05)

        border.fillColor = nil
        border.strokeColor = UIColor.systemIndigo.cgColor
        border.lineWidth = 2
        border.lineDashPattern = [7, 5]
        layer.addSublayer(border)

        rotateStem.backgroundColor = .systemIndigo
        addSubview(rotateStem)

        for knob in [resizeKnob, rotateKnob] as [UIView] {
            knob.backgroundColor = .systemIndigo
            knob.layer.cornerRadius = 14
            knob.layer.borderColor = UIColor.white.cgColor
            knob.layer.borderWidth = 3
            knob.layer.shadowOpacity = 0.25
            knob.layer.shadowRadius = 4
            knob.layer.shadowOffset = CGSize(width: 0, height: 2)
            knob.isUserInteractionEnabled = true
            addSubview(knob)
        }
        rotateKnob.image = UIImage(systemName: "arrow.clockwise",
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        rotateKnob.tintColor = .white
        rotateKnob.contentMode = .center

        let config = UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        deleteButton.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: config), for: .normal)
        deleteButton.tintColor = .systemRed
        deleteButton.backgroundColor = .white
        deleteButton.layer.cornerRadius = 15
        deleteButton.addAction(UIAction { [weak self] _ in self?.onAction?(.delete) }, for: .touchUpInside)
        addSubview(deleteButton)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        let rotation = UIRotationGestureRecognizer(target: self, action: #selector(rotation(_:)))
        for g in [pan, pinch, rotation] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
        resizeKnob.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(resizePan(_:))))
        rotateKnob.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(rotatePan(_:))))
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        border.frame = bounds
        border.path = UIBezierPath(roundedRect: bounds, cornerRadius: 6).cgPath
        resizeKnob.frame = CGRect(x: bounds.maxX - 14, y: bounds.maxY - 14, width: 28, height: 28)
        rotateKnob.frame = CGRect(x: bounds.midX - 14, y: -44, width: 28, height: 28)
        rotateStem.frame = CGRect(x: bounds.midX - 1, y: -16, width: 2, height: 16)
        deleteButton.frame = CGRect(x: bounds.maxX - 15, y: -15, width: 30, height: 30)
    }

    /// Griffe ragen über den Rand hinaus und sollen trotzdem antippbar sein.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -18, dy: -18).contains(point) || rotateKnob.frame.insetBy(dx: -10, dy: -10).contains(point)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g.view === other.view
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        onMove?(g.translation(in: superview), g.state)
        g.setTranslation(.zero, in: superview)
    }

    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        onPinch?(g.scale, g.state)
        g.scale = 1
    }

    @objc private func rotation(_ g: UIRotationGestureRecognizer) {
        onRotate?(g.rotation, g.state)
        g.rotation = 0
    }

    @objc private func resizePan(_ g: UIPanGestureRecognizer) {
        onResizeKnob?(g.location(in: superview), g.state)
    }

    @objc private func rotatePan(_ g: UIPanGestureRecognizer) {
        onRotateKnob?(g.location(in: superview), g.state)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let act: (String, String, Action, UIMenuElement.Attributes) -> UIAction = { title, symbol, action, attributes in
                UIAction(title: title, image: UIImage(systemName: symbol), attributes: attributes) { _ in self?.onAction?(action) }
            }
            return UIMenu(children: [
                act("Duplizieren", "plus.square.on.square", .duplicate, []),
                act("Nach vorne", "square.3.layers.3d.top.filled", .front, []),
                act("Nach hinten", "square.3.layers.3d.bottom.filled", .back, []),
                act("Drehung zurücksetzen", "arrow.counterclockwise", .resetRotation, []),
                act("Löschen", "trash", .delete, .destructive),
            ])
        }
    }
}

// MARK: - SwiftUI-Brücke

struct PageCanvas: UIViewRepresentable {
    @ObservedObject var model: EditorModel
    @ObservedObject var ink: InkSettings
    let store: LibraryStore
    let page: Page
    let fingerDrawing: Bool
    let flipDirection: FlipDirection
    let pencilAction: PencilAction

    func makeUIView(context: Context) -> PageCanvasHost {
        let notebookID = model.notebookID
        let pageID = page.id
        let host = PageCanvasHost(
            page: page,
            drawing: store.loadDrawing(notebook: notebookID, page: pageID),
            imageProvider: { [weak store] name in store?.image(name, notebook: notebookID) }
        )
        host.onDrawingChange = { [weak model] drawing in model?.drawingChanged(drawing, page: pageID) }
        host.onLasso = { [weak model] rect, drawing in model?.handleLasso(rect: rect, drawing: drawing, pageID: pageID) }
        host.onItemsChange = { [weak model] items in model?.setItems(items, pageID: pageID) }
        host.onFlip = { [weak model] delta in model?.flip(delta) }
        host.onImageTap = { [weak model] in model?.startImageEditing() }
        host.onEmptyTap = { [weak model] in model?.stopImageEditing() }
        model.host = host
        if let curl = model.takePendingCurl() { host.playCurl(curl.view, forward: curl.forward) }
        return host
    }

    func updateUIView(_ host: PageCanvasHost, context: Context) {
        host.update(page: page)
        host.canvas.tool = ink.pkTool
        host.aiMode = model.aiMode
        host.imageEditMode = model.imageEditMode
        host.geometryTool = model.geometryTool
        if host.rulerActive != model.rulerActive { host.rulerActive = model.rulerActive }
        if host.wholePageMode != model.wholePage { host.setWholePage(model.wholePage, animated: true) }
        if host.fingerDrawing != fingerDrawing { host.fingerDrawing = fingerDrawing }
        host.flipDirection = flipDirection
        let action = pencilAction
        host.onPencilAction = { [weak model] in model?.pencilAction(action) }
        if model.host !== host { model.host = host }
    }

}
