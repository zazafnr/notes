import SwiftUI
import PencilKit

/// Papier, Scans und Bilder. Liegt hinter der Tinte und wird beim Zoomen mit skaliert.
final class PaperBackgroundView: UIView {
    var page: Page { didSet { if oldValue != page { setNeedsDisplay() } } }
    let imageProvider: (String) -> UIImage?

    init(page: Page, imageProvider: @escaping (String) -> UIImage?) {
        self.page = page
        self.imageProvider = imageProvider
        super.init(frame: CGRect(origin: .zero, size: page.size))
        backgroundColor = .white
        isUserInteractionEnabled = false
        contentMode = .redraw
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 3)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        PageRenderer.drawBackground(page: page, image: imageProvider, in: ctx)
    }
}

/// Enthält die PencilKit-Zeichenfläche, den Papierhintergrund, die Bild-Griffe und die KI-Schleife.
final class PageCanvasHost: UIView, PKCanvasViewDelegate, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
    let canvas = PKCanvasView()
    let paper: PaperBackgroundView
    let imageOverlay = ImageEditOverlay()
    let lasso = LassoOverlayView()
    private(set) var page: Page

    var toolPicker: PKToolPicker?
    var flipDirection: FlipDirection = .horizontal
    var onDrawingChange: ((PKDrawing) -> Void)?
    var onLasso: ((CGRect, PKDrawing) -> Void)?
    var onPencilAction: (() -> Void)?
    var onItemsChange: (([PageImageItem]) -> Void)?
    var onFlip: ((Int) -> Void)?

    private var didInitialLayout = false
    private let insets = UIEdgeInsets(top: 84, left: 28, bottom: 140, right: 28)
    private var swipes: [UISwipeGestureRecognizer] = []

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
        addSubview(canvas)

        imageOverlay.paper = paper
        imageOverlay.isHidden = true
        imageOverlay.onChange = { [weak self] items, final in self?.itemsChanged(items, final: final) }
        addSubview(imageOverlay)

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

    private func updateInteraction() {
        canvas.drawingGestureRecognizer.isEnabled = !imageEditMode
        swipes.forEach { $0.isEnabled = !fingerDrawing && !aiMode && !imageEditMode }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        imageOverlay.frame = bounds
        lasso.frame = bounds
        guard bounds.width > 100 else { return }

        let fit = (bounds.width - insets.left - insets.right) / CGFloat(page.width)
        let wasAtFit = abs(canvas.zoomScale - canvas.minimumZoomScale) < 0.001
        canvas.minimumZoomScale = fit
        canvas.maximumZoomScale = fit * 5
        if !didInitialLayout || wasAtFit {
            canvas.zoomScale = fit
        }
        updateForZoom()
        if !didInitialLayout {
            canvas.contentOffset = CGPoint(x: -insets.left, y: -insets.top)
            didInitialLayout = true
            refreshPaperResolution()
        }
        imageOverlay.layoutHandles()
    }

    private func updateForZoom() {
        let z = canvas.zoomScale
        let size = CGSize(width: CGFloat(page.width) * z, height: CGFloat(page.height) * z)
        canvas.contentSize = size
        paper.bounds = CGRect(origin: .zero, size: page.size)
        paper.transform = CGAffineTransform(scaleX: z, y: z)
        paper.center = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// Papier nach dem Zoomen scharf neu zeichnen (begrenzt, um Speicher zu sparen).
    private func refreshPaperResolution() {
        let screenScale = window?.screen.scale ?? traitCollection.displayScale
        paper.contentScaleFactor = min(max(screenScale * canvas.zoomScale, 1), 3)
        paper.setNeedsDisplay()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, let picker = toolPicker else { return }
        picker.addObserver(canvas)
        picker.setVisible(true, forFirstResponder: canvas)
        Task { [weak self] in
            self?.canvas.becomeFirstResponder()
        }
    }

    func detachToolPicker() {
        toolPicker?.removeObserver(canvas)
    }

    // MARK: Scrollen & Zeichnen

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateForZoom()
        imageOverlay.layoutHandles()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        imageOverlay.layoutHandles()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        refreshPaperResolution()
    }

    /// Senkrechtes Blättern: über das Seitenende hinaus ziehen.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard flipDirection == .vertical, !aiMode, !imageEditMode else { return }
        let y = scrollView.contentOffset.y
        let maxY = scrollView.contentSize.height - scrollView.bounds.height + insets.bottom
        if y > maxY + 90 {
            onFlip?(1)
        } else if y < -insets.top - 90 {
            onFlip?(-1)
        }
    }

    @objc private func handleSwipe(_ swipe: UISwipeGestureRecognizer) {
        guard flipDirection == .horizontal,
              abs(canvas.zoomScale - canvas.minimumZoomScale) < 0.01 else { return }
        onFlip?(swipe.direction == .left ? 1 : -1)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        onDrawingChange?(canvasView.drawing)
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

// MARK: - Griffe zum Verschieben und Skalieren von Bildern

final class ImageEditOverlay: UIView {
    weak var paper: UIView?
    var onChange: (([PageImageItem], Bool) -> Void)?
    private(set) var isDragging = false

    private var items: [PageImageItem] = []
    private var handles: [UUID: ImageHandleView] = [:]
    private var startFrame: CGRect = .zero

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
            handle.onMove = { [weak self] t, state in self?.move(id, translation: t, state: state) }
            handle.onResize = { [weak self] t, state in self?.resize(id, translation: t, state: state) }
            handle.onDelete = { [weak self] in self?.delete(id) }
            addSubview(handle)
            handles[id] = handle
        }
    }

    func layoutHandles() {
        guard let paper, !isHidden else { return }
        for item in items {
            handles[item.id]?.frame = paper.convert(item.frame, to: self)
        }
    }

    private var scale: CGFloat { max(paper?.transform.a ?? 1, 0.01) }
    private var pageBounds: CGRect { paper?.bounds ?? .zero }

    private func begin(_ id: UUID, state: UIGestureRecognizer.State) -> Int? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        if state == .began {
            startFrame = items[i].frame
            isDragging = true
            Haptics.tap()
        }
        return i
    }

    private func finish(_ state: UIGestureRecognizer.State) {
        layoutHandles()
        let final = state == .ended || state == .cancelled
        if final { isDragging = false }
        onChange?(items, final)
    }

    private func move(_ id: UUID, translation: CGPoint, state: UIGestureRecognizer.State) {
        guard let i = begin(id, state: state) else { return }
        var f = startFrame
        f.origin.x += translation.x / scale
        f.origin.y += translation.y / scale
        f.origin.x = min(max(f.origin.x, -f.width * 0.5), pageBounds.width - f.width * 0.5)
        f.origin.y = min(max(f.origin.y, -f.height * 0.5), pageBounds.height - f.height * 0.5)
        items[i].frame = f
        finish(state)
    }

    private func resize(_ id: UUID, translation: CGPoint, state: UIGestureRecognizer.State) {
        guard let i = begin(id, state: state), startFrame.width > 0 else { return }
        let aspect = startFrame.height / startFrame.width
        let width = min(max(startFrame.width + translation.x / scale, 60), pageBounds.width * 1.2)
        items[i].frame.size = CGSize(width: width, height: width * aspect)
        finish(state)
    }

    private func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        setItems(items)
        Haptics.success()
        onChange?(items, true)
    }
}

final class ImageHandleView: UIView {
    var onMove: ((CGPoint, UIGestureRecognizer.State) -> Void)?
    var onResize: ((CGPoint, UIGestureRecognizer.State) -> Void)?
    var onDelete: (() -> Void)?

    private let border = CAShapeLayer()
    private let knob = UIView()
    private let deleteButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemIndigo.withAlphaComponent(0.06)

        border.fillColor = nil
        border.strokeColor = UIColor.systemIndigo.cgColor
        border.lineWidth = 2
        border.lineDashPattern = [7, 5]
        layer.addSublayer(border)

        knob.backgroundColor = .systemIndigo
        knob.layer.cornerRadius = 13
        knob.layer.borderColor = UIColor.white.cgColor
        knob.layer.borderWidth = 3
        knob.layer.shadowOpacity = 0.25
        knob.layer.shadowRadius = 4
        knob.layer.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(knob)

        let config = UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        deleteButton.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: config), for: .normal)
        deleteButton.tintColor = .systemRed
        deleteButton.backgroundColor = .white
        deleteButton.layer.cornerRadius = 15
        deleteButton.addAction(UIAction { [weak self] _ in self?.onDelete?() }, for: .touchUpInside)
        addSubview(deleteButton)

        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        knob.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(resizePan(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        border.frame = bounds
        border.path = UIBezierPath(roundedRect: bounds, cornerRadius: 6).cgPath
        knob.frame = CGRect(x: bounds.maxX - 13, y: bounds.maxY - 13, width: 26, height: 26)
        deleteButton.frame = CGRect(x: bounds.maxX - 15, y: -15, width: 30, height: 30)
    }

    /// Griffe ragen über den Rand hinaus und sollen trotzdem antippbar sein.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -18, dy: -18).contains(point)
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        onMove?(g.translation(in: superview), g.state)
    }

    @objc private func resizePan(_ g: UIPanGestureRecognizer) {
        onResize?(g.translation(in: superview), g.state)
    }
}

struct PageCanvas: UIViewRepresentable {
    @ObservedObject var model: EditorModel
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
        host.toolPicker = model.toolPicker
        host.onDrawingChange = { [weak model] drawing in model?.drawingChanged(drawing, page: pageID) }
        host.onLasso = { [weak model] rect, drawing in model?.handleLasso(rect: rect, drawing: drawing, pageID: pageID) }
        host.onItemsChange = { [weak model] items in model?.setItems(items, pageID: pageID) }
        host.onFlip = { [weak model] delta in model?.flip(delta) }
        model.host = host
        return host
    }

    func updateUIView(_ host: PageCanvasHost, context: Context) {
        host.update(page: page)
        host.aiMode = model.aiMode
        host.imageEditMode = model.imageEditMode
        if host.fingerDrawing != fingerDrawing { host.fingerDrawing = fingerDrawing }
        host.flipDirection = flipDirection
        let action = pencilAction
        host.onPencilAction = { [weak model] in model?.pencilAction(action) }
        if model.host !== host { model.host = host }
    }

    static func dismantleUIView(_ host: PageCanvasHost, coordinator: ()) {
        host.detachToolPicker()
    }
}
