import XCTest
import CoreGraphics
@testable import FreeNotesLogic

final class HandwritingFontTests: XCTestCase {
    func testBuiltInFontHasAllCharacters() {
        let font = HandwritingFont.builtIn
        let needed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789äöüÄÖÜß.,:;!?-+=()/"
        for ch in needed {
            XCTAssertNotNil(font.glyphs[String(ch)]?.first, "»\(ch)« fehlt")
        }
        // Mehrere Varianten für häufige Buchstaben
        XCTAssertGreaterThan(font.glyphs["e"]?.count ?? 0, 2)
    }

    func testGlyphsAreNormalized() {
        for (key, variants) in HandwritingFont.builtIn.glyphs {
            for glyph in variants {
                let points = glyph.strokes.flatMap { $0 }
                XCTAssertFalse(points.isEmpty, "»\(key)« ohne Striche")
                let minX = points.map(\.x).min() ?? 0
                XCTAssertGreaterThan(minX, -0.2, "»\(key)« beginnt links von 0")
                let ys = points.map(\.y)
                XCTAssertGreaterThan(ys.min() ?? 0, -3.6, "»\(key)« zu hoch")
                XCTAssertLessThan(ys.max() ?? 0, 2.0, "»\(key)« zu tief")
            }
        }
    }

    func testResolveFallbacks() {
        let font = HandwritingFont.builtIn
        let sup = font.resolve("²")
        XCTAssertEqual(sup?.key, "2")
        XCTAssertLessThan(sup?.scale ?? 1, 1)
        XCTAssertGreaterThan(sup?.raise ?? 0, 0)
        XCTAssertEqual(font.resolve("é")?.key, "e")
        XCTAssertEqual(font.resolve("–")?.key, "-")
        XCTAssertEqual(font.resolve("„")?.key, "\"")
        XCTAssertNil(font.resolve("😀"))
    }

    func testCustomGlyphsReplaceBuiltIn() {
        let custom = HWGlyph(strokes: [[CGPoint(x: 2, y: -1), CGPoint(x: 2.5, y: 0)]])!
        XCTAssertEqual(custom.w, 0.5, accuracy: 0.001)
        XCTAssertEqual(custom.strokes[0][0].x, 0, accuracy: 0.001)
        let merged = HandwritingFont.builtIn.merged(with: ["a": [custom]])
        XCTAssertEqual(merged.glyphs["a"], [custom])
    }

    func testSeededRandomIsDeterministic() {
        var a = SeededRandom(seed: 5)
        var b = SeededRandom(seed: 5)
        for _ in 0..<20 { XCTAssertEqual(a.next(), b.next()) }
        var c = SeededRandom(seed: 9)
        for _ in 0..<200 {
            let u = c.unit()
            XCTAssertTrue(u >= 0 && u < 1)
        }
    }
}

final class HandwritingLayoutTests: XCTestCase {
    let font = HandwritingFont.builtIn
    let size = CGSize(width: 1000, height: 1414)

    func testSameSeedSameResult() {
        let ruling = HWRuling.forPaper(.lined, size: size)
        let style = HWStyle(xHeight: 12.5)
        let a = HandwritingLayout.layout("Hallo Welt", font: font, style: style, ruling: ruling, seed: 3)
        let b = HandwritingLayout.layout("Hallo Welt", font: font, style: style, ruling: ruling, seed: 3)
        XCTAssertEqual(a, b)
        let c = HandwritingLayout.layout("Hallo Welt", font: font, style: style, ruling: ruling, seed: 4)
        XCTAssertNotEqual(a.strokes, c.strokes)
    }

    func testStaysWithinMarginsAndWraps() {
        let ruling = HWRuling.forPaper(.lined, size: size)
        let style = HWStyle(xHeight: 12.5)
        let text = Array(repeating: "Photosynthese wandelt Lichtenergie in chemische Energie um.", count: 4).joined(separator: " ")
        let layout = HandwritingLayout.layout(text, font: font, style: style, ruling: ruling, seed: 1)
        XCTAssertNil(layout.overflow)
        XCTAssertTrue(layout.missing.isEmpty)
        let bounds = layout.bounds
        XCTAssertGreaterThanOrEqual(bounds.minX, ruling.left - 3)
        XCTAssertLessThanOrEqual(bounds.maxX, ruling.right + 12)
        // Mehrere Zeilen, jede auf einer Heftlinie
        XCTAssertGreaterThan(layout.lastBaseline, ruling.firstBaseline + ruling.lineHeight * 2)
        let lineOffset = (layout.lastBaseline - 130).truncatingRemainder(dividingBy: 38)
        XCTAssertEqual(lineOffset, 0, accuracy: 0.001)
        // Jedes Wort endet mit einer Markierung (zum Zwischenspeichern beim Animieren)
        XCTAssertEqual(layout.strokes.filter(\.endsWord).count, text.split(separator: " ").count)
    }

    func testOverflowKeepsAllWords() {
        let ruling = HWRuling(lineHeight: 38, firstBaseline: 100, left: 50, right: 400, bottom: 176, preferredXHeight: 12)
        let words = (1...40).map { "Wort\($0)" }
        let layout = HandwritingLayout.layout(words.joined(separator: " "), font: font,
                                              style: HWStyle(xHeight: 12), ruling: ruling, seed: 2)
        guard let overflow = layout.overflow else { return XCTFail("Text hätte nicht passen dürfen") }
        XCTAssertLessThanOrEqual(layout.lastBaseline, 176)
        let written = layout.strokes.filter(\.endsWord).count
        XCTAssertEqual(written + overflow.split(separator: " ").count, words.count)
        XCTAssertTrue(overflow.hasSuffix("Wort40"))
    }

    func testOverflowKeepsFollowingLines() {
        let ruling = HWRuling(lineHeight: 38, firstBaseline: 100, left: 50, right: 900, bottom: 140, preferredXHeight: 12)
        let layout = HandwritingLayout.layout("a) eins\nb) zwei\nc) drei\nd) vier", font: font,
                                              style: HWStyle(xHeight: 12), ruling: ruling, seed: 2)
        XCTAssertEqual(layout.overflow, "c) drei\nd) vier")
    }

    func testMarkupParsingAndUnderline() {
        let lines = HandwritingLayout.parse("A: ==x = 7== und __so__")
        XCTAssertEqual(lines.count, 1)
        let marks = lines[0].map(\.underline)
        let text = String(lines[0].map(\.char))
        XCTAssertEqual(text, "A: x = 7 und so")
        XCTAssertEqual(marks[3], 2)  // »x«
        XCTAssertEqual(marks[0], 0)
        XCTAssertEqual(marks.last, 1)
        XCTAssertEqual(HandwritingLayout.serialize(lines), "A: ==x = 7== und __so__")

        let ruling = HWRuling.forPaper(.lined, size: size)
        let plain = HandwritingLayout.layout("x = 7", font: font, style: HWStyle(xHeight: 12), ruling: ruling, seed: 1)
        let double = HandwritingLayout.layout("==x = 7==", font: font, style: HWStyle(xHeight: 12), ruling: ruling, seed: 1)
        XCTAssertEqual(double.strokes.count, plain.strokes.count + 2)
    }

    func testSuperscriptIsSmallAndRaised() {
        let ruling = HWRuling.forPaper(.blank, size: size)
        let layout = HandwritingLayout.layout("²", font: font, style: HWStyle(xHeight: 12, messiness: 0), ruling: ruling, seed: 1)
        let b = layout.bounds
        XCTAssertLessThan(b.maxY, ruling.firstBaseline - 6)
    }

    func testFitInBox() {
        let rect = CGRect(x: 300, y: 500, width: 160, height: 26)
        let layout = HandwritingLayout.fit("Paris ist die Hauptstadt", in: rect, font: font, style: HWStyle(xHeight: 12), seed: 1)
        XCTAssertNil(layout.overflow)
        let b = layout.bounds
        XCTAssertGreaterThanOrEqual(b.minX, rect.minX - 2)
        XCTAssertLessThanOrEqual(b.maxX, rect.maxX + 8)
        // sitzt auf der Unterkante (Schreiblinie)
        XCTAssertEqual(layout.lastBaseline, Double(rect.maxY), accuracy: 4)
    }

    func testRulingBaselineSkipsALine() {
        let ruling = HWRuling.forPaper(.lined, size: size)
        XCTAssertEqual(ruling.baseline(below: nil), ruling.firstBaseline)
        // Geschriebenes endet knapp unter der Linie bei 206 → eine Zeile frei → 282
        XCTAssertEqual(ruling.baseline(below: 212), 282)
        let grid = HWRuling.forPaper(.grid, size: size)
        XCTAssertEqual(grid.firstBaseline.truncatingRemainder(dividingBy: 25), 0)
        XCTAssertLessThanOrEqual(ruling.xHeight(scale: 1.25) * 3.1, ruling.lineHeight * 1.1)
    }
}

final class HandwritingPromptTests: XCTestCase {
    func testCleanNotebookText() {
        let raw = "```\n# **Nr. 3**\n\n\n* x = 7\n$a^2$\n```"
        XCTAssertEqual(HandwritingPrompts.cleanNotebookText(raw), "Nr. 3\n\n- x = 7\na^2")
    }

    func testHeaderInstruction() {
        let with = HandwritingPrompts.notebookUser(answer: "x = 7", question: nil, header: .pageAndNumber(nil))
        XCTAssertTrue(with.contains("S. 42 Nr. 3"))
        let without = HandwritingPrompts.notebookUser(answer: "x = 7", question: nil, header: .none)
        XCTAssertFalse(without.contains("S. 42"))
    }

    func testWorksheetParse() {
        let raw = """
        Hier ist das Ergebnis:
        ```json
        {"felder":[{"text":"Berlin","x":110,"y":220,"w":220,"h":33},{"text":"","x":1,"y":1,"w":50,"h":50},{"text":"zu klein","x":1,"y":1,"w":1,"h":1}]}
        ```
        """
        let fields = WorksheetField.parse(raw, imageScale: 1.1, pageSize: CGSize(width: 1000, height: 1414))
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0].text, "Berlin")
        XCTAssertEqual(fields[0].rect.minX, 100, accuracy: 0.01)
        XCTAssertEqual(fields[0].rect.height, 30, accuracy: 0.01)
        XCTAssertTrue(WorksheetField.parse("keine Ahnung", imageScale: 1, pageSize: .zero).isEmpty)
    }
}

final class PageRotationTests: XCTestCase {
    func testRotationSwapsSizeAndMovesItems() {
        var page = Page(paper: .grid)
        page.items = [PageImageItem(asset: "a.jpg", frame: CGRect(x: 100, y: 200, width: 300, height: 100))]
        let right = page.rotated(clockwise: true)
        XCTAssertEqual(right.width, page.height)
        XCTAssertEqual(right.height, page.width)
        // Ecke oben links wandert nach oben rechts
        let t = Page.rotationTransform(size: page.size, clockwise: true)
        let corner = CGPoint.zero.applying(t)
        XCTAssertEqual(corner.x, CGFloat(page.height), accuracy: 0.001)
        XCTAssertEqual(corner.y, 0, accuracy: 0.001)
        // Viermal drehen ergibt wieder das Original
        var turned = page
        for _ in 0..<4 { turned = turned.rotated(clockwise: true) }
        XCTAssertEqual(turned.size, page.size)
        XCTAssertEqual(turned.items[0].frame.minX, page.items[0].frame.minX, accuracy: 0.001)
        XCTAssertEqual(turned.items[0].frame.minY, page.items[0].frame.minY, accuracy: 0.001)
        // Links und rechts heben sich auf
        let back = page.rotated(clockwise: true).rotated(clockwise: false)
        XCTAssertEqual(back.items[0].center.x, page.items[0].center.x, accuracy: 0.001)
        XCTAssertEqual(back.items[0].angle, 0, accuracy: 0.0001)
    }
}

final class WorksheetPromptTests: XCTestCase {
    func testTaskAreaLimitsFields() {
        let ocr = [HandwritingPrompts.OCRLine(text: "Nr. 3", rect: CGRect(x: 10, y: 20, width: 40, height: 12))]
        let text = HandwritingPrompts.worksheetUser(imageSize: CGSize(width: 1100, height: 1555), ocr: ocr,
                                                    solutions: "a) 12", taskRect: CGRect(x: 100, y: 200, width: 300, height: 150))
        XCTAssertTrue(text.contains("[100, 200, 300, 150]"))
        XCTAssertTrue(text.contains("NUR diese"))
        XCTAssertTrue(text.contains("[10, 20, 40, 12] Nr. 3"))
        let plain = HandwritingPrompts.worksheetUser(imageSize: CGSize(width: 1100, height: 1555), ocr: [], solutions: nil)
        XCTAssertFalse(plain.contains("eingekreist"))
    }
}

final class WorksheetVisionTests: XCTestCase {
    func testCropMapping() {
        let crop = WorksheetCrop(area: CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.1), pageSize: CGSize(width: 1000, height: 1414))
        XCTAssertLessThanOrEqual(max(crop.pixelSize.width, crop.pixelSize.height), 1561)
        XCTAssertGreaterThan(crop.scale, 2)
        let r = CGRect(x: 300, y: 450, width: 100, height: 30)
        let back = crop.toPage(crop.toPixels(r))
        XCTAssertEqual(back.minX, r.minX, accuracy: 0.001)
        XCTAssertEqual(back.height, r.height, accuracy: 0.001)
        // Ganze Seite, wenn nichts eingekreist ist
        let whole = WorksheetCrop(area: nil, pageSize: CGSize(width: 1000, height: 1414))
        XCTAssertEqual(whole.region, CGRect(x: 0, y: 0, width: 1000, height: 1414))
    }

    func testSnapsOntoLineAndIntoCell() {
        var img = WorksheetVision.Gray(width: 600, height: 300)
        // Tabellenzeile: Linien bei y = 100 und y = 160 (2 px dick)
        img.fill(CGRect(x: 50, y: 100, width: 500, height: 2))
        img.fill(CGRect(x: 50, y: 160, width: 500, height: 2))
        // Text in einer anderen Zeile (soll nicht als Linie gelten)
        for i in 0..<30 { img.fill(CGRect(x: 60 + i * 15, y: 220, width: 8, height: 22)) }
        let ink = WorksheetVision.inkMask(img)
        // KI-Schätzung etwas zu tief und zu groß
        let snapped = WorksheetVision.snap(CGRect(x: 100, y: 115, width: 300, height: 60), ink: ink, width: 600, height: 300, unit: 2)
        XCTAssertLessThan(snapped.maxY, 160)
        XCTAssertGreaterThan(snapped.maxY, 150)
        XCTAssertGreaterThan(snapped.minY, 100)
        // Keine Linie in der Nähe: bleibt unverändert
        let free = CGRect(x: 100, y: 20, width: 200, height: 30)
        XCTAssertEqual(WorksheetVision.snap(free, ink: ink, width: 600, height: 300, unit: 2), free)
        // Textzeile ist keine Linie
        XCTAssertFalse(WorksheetVision.isLine(ink, width: 600, height: 300, y: 231, x0: 60, x1: 500, unit: 2))
        XCTAssertTrue(WorksheetVision.isLine(ink, width: 600, height: 300, y: 101, x0: 60, x1: 500, unit: 2))
    }

    func testJSONObjectsSurviveNoiseAndTruncation() {
        let raw = """
        Klar! ```json
        {"felder":[{"text":"a {b}","x":1,"y":2,"w":30,"h":10},{"text":"zwei","x":"5","y":6,"w":40,"h":12},{"text":"abgeschn
        """
        let fields = WorksheetField.pixelFields(raw)
        XCTAssertEqual(fields.map(\.text), ["a {b}", "zwei"])
        XCTAssertEqual(fields[1].rect.minX, 5)
    }
}
