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

/// Enthält die PencilKit-Zeichenfläche, den Papierhintergrund und die KI-Schleife.
final class PageCanvasHost: UIView, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    let canvas = PKCanvasView()
    let paper: PaperBackgroundView
    let lasso = LassoOverlayView()
    private(set) var page: Page

    var toolPicker: PKToolPicker?
    var onDrawingChange: ((PKDrawing) -> Void)?
    var onLasso: ((CGRect, PKDrawing) -> Void)?
    var onPencilAction: (() -> Void)?

    private var didInitialLayout = false
    private let insets = UIEdgeInsets(top: 84, left: 28, bottom: 140, right: 28)

    var aiMode = false {
        didSet {
            guard aiMode != oldValue else { return }
            lasso.isHidden = !aiMode
            lasso.reset()
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

        lasso.isHidden = true
        lasso.onComplete = { [weak self] path in self?.handleLasso(path) }
        addSubview(lasso)

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(page newPage: Page) {
        guard newPage != page else { return }
        let sizeChanged = newPage.size != page.size
        page = newPage
        paper.page = newPage
        if sizeChanged {
            didInitialLayout = false
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
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
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        refreshPaperResolution()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        onDrawingChange?(canvasView.drawing)
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

struct PageCanvas: UIViewRepresentable {
    @ObservedObject var model: EditorModel
    let store: LibraryStore
    let page: Page
    let fingerDrawing: Bool

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
        host.onPencilAction = { [weak model] in model?.toggleAIMode() }
        model.host = host
        return host
    }

    func updateUIView(_ host: PageCanvasHost, context: Context) {
        host.update(page: page)
        host.aiMode = model.aiMode
        host.canvas.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        if model.host !== host { model.host = host }
    }

    static func dismantleUIView(_ host: PageCanvasHost, coordinator: ()) {
        host.detachToolPicker()
    }
}
