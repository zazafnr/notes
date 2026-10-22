import UIKit
import PencilKit

/// Zeichnet Papier, Scans, Bilder und Tinte einer Seite (in Seitenkoordinaten).
@MainActor
enum PageRenderer {
    static let lineColor = UIColor(red: 0.55, green: 0.70, blue: 0.90, alpha: 0.55)
    static let gridColor = UIColor(white: 0.50, alpha: 0.25)
    static let marginColor = UIColor(red: 0.93, green: 0.42, blue: 0.42, alpha: 0.45)

    static func drawPaper(_ style: PaperStyle, size: CGSize, in ctx: CGContext) {
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        switch style {
        case .blank:
            break
        case .lined:
            ctx.setStrokeColor(lineColor.cgColor)
            ctx.setLineWidth(1.2)
            var y: CGFloat = 130
            while y < size.height - 40 {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: size.width, y: y))
                y += 38
            }
            ctx.strokePath()
            ctx.setStrokeColor(marginColor.cgColor)
            ctx.move(to: CGPoint(x: 90, y: 0))
            ctx.addLine(to: CGPoint(x: 90, y: size.height))
            ctx.strokePath()
        case .grid:
            ctx.setStrokeColor(gridColor.cgColor)
            ctx.setLineWidth(1)
            let step: CGFloat = 25
            var x = step
            while x < size.width {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y = step
            while y < size.height {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            ctx.strokePath()
        case .dotted:
            ctx.setFillColor(UIColor(white: 0.45, alpha: 0.45).cgColor)
            let step: CGFloat = 30
            var y = step
            while y < size.height {
                var x = step
                while x < size.width {
                    ctx.fillEllipse(in: CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2))
                    x += step
                }
                y += step
            }
        }
    }

    static func drawBackground(page: Page, image: (String) -> UIImage?, in ctx: CGContext) {
        drawPaper(page.paper, size: page.size, in: ctx)
        UIGraphicsPushContext(ctx)
        if let bg = page.background, let img = image(bg) {
            img.draw(in: page.bounds)
        }
        for item in page.items {
            image(item.asset)?.draw(in: item.frame)
        }
        UIGraphicsPopContext()
    }

    /// Tinte immer im hellen Modus rendern, sonst wird schwarze Schrift im Dunkelmodus weiß.
    static func ink(_ drawing: PKDrawing, rect: CGRect, scale: CGFloat) -> UIImage {
        var result = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            result = drawing.image(from: rect, scale: scale)
        }
        return result
    }

    static func render(page: Page, drawing: PKDrawing, image: (String) -> UIImage?,
                       rect: CGRect? = nil, scale: CGFloat) -> UIImage {
        let r = rect ?? page.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let inkImage = ink(drawing, rect: r, scale: scale)
        return UIGraphicsImageRenderer(size: r.size, format: format).image { context in
            let ctx = context.cgContext
            ctx.translateBy(x: -r.minX, y: -r.minY)
            drawBackground(page: page, image: image, in: ctx)
            inkImage.draw(in: r)
        }
    }

    /// Exportiert ein ganzes Heft als PDF.
    static func pdf(notebook: Notebook, drawing: (Page) -> PKDrawing, image: (String) -> UIImage?, to url: URL) throws {
        guard let first = notebook.pages.first else { return }
        let renderer = UIGraphicsPDFRenderer(bounds: first.bounds)
        try renderer.writePDF(to: url) { context in
            for page in notebook.pages {
                context.beginPage(withBounds: page.bounds, pageInfo: [:])
                drawBackground(page: page, image: image, in: context.cgContext)
                let inkImage = ink(drawing(page), rect: page.bounds, scale: 2)
                UIGraphicsPushContext(context.cgContext)
                inkImage.draw(in: page.bounds)
                UIGraphicsPopContext()
            }
        }
    }
}
