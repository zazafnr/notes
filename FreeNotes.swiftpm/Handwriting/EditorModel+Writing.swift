import SwiftUI
import PencilKit

/// Ein Stück Handschrift für eine Seite.
struct WritingPart {
    var pageID: UUID
    var strokes: [HWStroke]
    var xHeight: Double
}

/// Für die Anzeige »Schreibt … Seite 1 von 2«.
struct WritingStatus: Equatable {
    var pages: Int
    var page: Int
}

/// Wohin der Text geschrieben wird.
enum WritePlacement: String, CaseIterable, Identifiable {
    case below, newPage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .below: return "Unter das Geschriebene"
        case .newPage: return "Auf eine neue Seite"
        }
    }
}

extension EditorModel {
    // MARK: Planen

    /// Wo auf der Seite schon etwas steht (unterste Kante von Tinte und Bildern).
    func contentBottom(of page: Page, drawing: PKDrawing) -> Double? {
        var bottom: CGFloat?
        if !drawing.strokes.isEmpty { bottom = drawing.bounds.maxY }
        for item in page.items {
            bottom = max(bottom ?? 0, item.boundingBox.maxY)
        }
        return bottom.map(Double.init)
    }

    /// Ist auf der aktuellen Seite noch nichts geschrieben?
    var currentPageIsEmpty: Bool {
        guard let page = currentPage else { return true }
        let drawing = host?.canvas.drawing ?? store.loadDrawing(notebook: notebookID, page: page.id)
        return page.background == nil && page.items.isEmpty && drawing.strokes.isEmpty
    }

    /// Kann unter dem Vorhandenen weitergeschrieben werden (kein Scan, noch mindestens zwei Zeilen frei)?
    var canWriteBelow: Bool {
        guard let page = currentPage, page.background == nil else { return false }
        let drawing = host?.canvas.drawing ?? store.loadDrawing(notebook: notebookID, page: page.id)
        let ruling = HWRuling.forPaper(page.paper, size: page.size)
        return ruling.baseline(below: contentBottom(of: page, drawing: drawing)) <= ruling.bottom - ruling.lineHeight
    }

    /// Papier für neue Seiten: wie die aktuelle Seite, bei Scans das Papier des Hefts.
    private var paperForNewPages: PaperStyle {
        if let page = currentPage, page.background == nil { return page.paper }
        let paper = notebook?.paper ?? .lined
        return paper == .blank ? .lined : paper
    }

    /// Setzt den Text auf eine Seite mit diesem Papier (für die Vorschau).
    func previewLayout(_ text: String, paper: PaperStyle, size: CGSize) -> (HWLayout, Double) {
        let hw = HandwritingStore.shared
        let ruling = HWRuling.forPaper(paper, size: size)
        let xh = ruling.xHeight(scale: hw.size)
        return (HandwritingLayout.layout(text, font: hw.font, style: hw.style(xHeight: xh), ruling: ruling, seed: 7), xh)
    }

    // MARK: Schreiben

    /// Schreibt Text in der eigenen Handschrift ins Heft – passt er nicht, geht es auf neuen Seiten weiter.
    func writeHandwriting(_ text: String, placement: WritePlacement) {
        guard let page = currentPage, !text.trimmed.isEmpty else { return }
        skipWriting()
        flush()
        let hw = HandwritingStore.shared
        let font = hw.font
        var seed = UInt64(Date().timeIntervalSince1970 * 1000) & 0xFFFF_FFFF
        var parts: [WritingPart] = []
        var remaining: String? = text

        if placement == .below, page.background == nil {
            let drawing = host?.canvas.drawing ?? store.loadDrawing(notebook: notebookID, page: page.id)
            let ruling = HWRuling.forPaper(page.paper, size: page.size)
            let xh = ruling.xHeight(scale: hw.size)
            let start = ruling.baseline(below: contentBottom(of: page, drawing: drawing))
            if start <= ruling.bottom - ruling.lineHeight {
                let layout = HandwritingLayout.layout(text, font: font, style: hw.style(xHeight: xh),
                                                      ruling: ruling, startBaseline: start, seed: seed)
                parts.append(WritingPart(pageID: page.id, strokes: layout.strokes, xHeight: xh))
                remaining = layout.overflow
                seed &+= 1
            }
        }

        var newPages: [Page] = []
        let paper = paperForNewPages
        while let rest = remaining, !rest.trimmed.isEmpty, newPages.count < 20 {
            let newPage = Page(paper: paper)
            let ruling = HWRuling.forPaper(paper, size: newPage.size)
            let xh = ruling.xHeight(scale: hw.size)
            let layout = HandwritingLayout.layout(rest, font: font, style: hw.style(xHeight: xh), ruling: ruling, seed: seed)
            seed &+= 1
            newPages.append(newPage)
            parts.append(WritingPart(pageID: newPage.id, strokes: layout.strokes, xHeight: xh))
            // Sicherheitsnetz: nichts geschrieben, aber noch Text übrig → abbrechen statt endlos Seiten anlegen
            if layout.strokes.isEmpty { break }
            remaining = layout.overflow
        }
        if !newPages.isEmpty {
            let insertAt = pageIndex + 1
            store.updateNotebook(notebookID) { nb in
                nb.pages.insert(contentsOf: newPages, at: min(insertAt, nb.pages.count))
            }
        }
        startWriting(parts)
    }

    /// Trägt Antworten in die Felder eines Arbeitsblatts auf der aktuellen Seite ein.
    func writeFields(_ fields: [WorksheetField]) {
        guard let page = currentPage, !fields.isEmpty else { return }
        skipWriting()
        flush()
        let hw = HandwritingStore.shared
        let xh = 11.5 * hw.size
        var strokes: [HWStroke] = []
        // Von oben nach unten, wie man ein Blatt ausfüllt
        let ordered = fields.sorted { a, b in
            abs(a.rect.minY - b.rect.minY) < 8 ? a.rect.minX < b.rect.minX : a.rect.minY < b.rect.minY
        }
        for (index, field) in ordered.enumerated() {
            let layout = HandwritingLayout.fit(field.text, in: field.rect, font: hw.font,
                                               style: hw.style(xHeight: xh), seed: UInt64(index + 11))
            strokes += layout.strokes
        }
        startWriting([WritingPart(pageID: page.id, strokes: strokes, xHeight: xh)])
    }

    private func startWriting(_ parts: [WritingPart]) {
        let parts = parts.filter { !$0.strokes.isEmpty }
        guard !parts.isEmpty else { return }
        writingQueue = parts
        skipWritingAnimation = HandwritingStore.shared.speed.factor == nil
        writing = WritingStatus(pages: Set(parts.map(\.pageID)).count, page: 1)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            aiMode = false
            imageEditMode = false
            geometryTool = nil
            showPanel = false
        }
        continueWriting()
    }

    /// Nächstes Stück schreiben: zur richtigen Seite blättern und dort animiert schreiben.
    func continueWriting() {
        guard animator == nil else { return }
        guard let part = writingQueue.first else {
            if writing != nil {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { writing = nil }
                Haptics.success()
            }
            return
        }
        if skipWritingAnimation {
            // Alles sofort: aktuelle Seite über die Zeichenfläche, andere direkt in die Datei
            for part in writingQueue { writeDirectly(part) }
            writingQueue = []
            skipWritingAnimation = false
            continueWriting()
            return
        }
        guard let index = notebook?.pages.firstIndex(where: { $0.id == part.pageID }) else {
            writingQueue.removeFirst()
            continueWriting()
            return
        }
        if index != pageIndex {
            navigatingForWriting = true
            goTo(index)
            navigatingForWriting = false
            return   // geht weiter, sobald die Seite angezeigt wird (host)
        }
        guard let host, host.page.id == part.pageID else { return }
        writingQueue.removeFirst()
        let total = writing?.pages ?? 1
        writing = WritingStatus(pages: total, page: min(total, total - Set(writingQueue.map(\.pageID)).count))
        let animator = HandwritingAnimator(strokes: part.strokes, color: HandwritingInk.color,
                                           size: HandwritingInk.pointSize(penWidth: ink.penWidth, xHeight: part.xHeight),
                                           xHeight: part.xHeight, speed: HandwritingStore.shared.speed.factor ?? 4)
        animator.onFinish = { [weak self] in
            guard let self else { return }
            self.animator = nil
            if self.writingQueue.isEmpty || self.skipWritingAnimation {
                self.continueWriting()
            } else {
                // Kurz innehalten, dann umblättern
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    self?.continueWriting()
                }
            }
        }
        self.animator = animator
        animator.start(on: host)
    }

    /// Überspringen: Rest sofort hinschreiben.
    func skipWriting() {
        guard writing != nil || animator != nil || !writingQueue.isEmpty else { return }
        skipWritingAnimation = true
        if let animator {
            animator.finishNow()   // ruft continueWriting über onFinish
        } else {
            continueWriting()
        }
    }

    var writingProgress: Double { animator?.progress ?? 1 }

    private func writeDirectly(_ part: WritingPart) {
        let strokes = HandwritingInk.pkStrokes(part.strokes, color: HandwritingInk.color,
                                               size: HandwritingInk.pointSize(penWidth: ink.penWidth, xHeight: part.xHeight),
                                               xHeight: part.xHeight)
        if let host, host.page.id == part.pageID {
            let before = host.canvas.drawing
            host.appendStrokes(strokes)
            host.registerReplaceUndo(before: before, after: host.canvas.drawing)
        } else {
            var drawing = store.loadDrawing(notebook: notebookID, page: part.pageID)
            drawing.strokes.append(contentsOf: strokes)
            store.saveDrawing(drawing, notebook: notebookID, page: part.pageID)
            store.updateNotebook(notebookID) { _ in }
        }
    }
}
