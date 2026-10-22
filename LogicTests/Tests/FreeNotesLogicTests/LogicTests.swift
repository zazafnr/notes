import XCTest
@testable import FreeNotesLogic

final class StreamParsingTests: XCTestCase {
    func testTextChunk() {
        let line = #"data: {"choices":[{"delta":{"content":"Hallo"}}]}"#
        XCTAssertEqual(AIClient.parseEvent(line), .text("Hallo"))
    }

    func testDone() {
        XCTAssertEqual(AIClient.parseEvent("data: [DONE]"), .done)
    }

    func testIgnoresCommentsAndEmptyDeltas() {
        XCTAssertNil(AIClient.parseEvent(": OPENROUTER PROCESSING"))
        XCTAssertNil(AIClient.parseEvent(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#))
        XCTAssertNil(AIClient.parseEvent(#"data: {"choices":[{"delta":{"content":""}}]}"#))
    }

    func testErrorInsideStream() {
        let line = #"data: {"error":{"message":"Rate limit exceeded","code":429}}"#
        guard case .error(let payload) = AIClient.parseEvent(line) else { return XCTFail("kein Fehler erkannt") }
        XCTAssertTrue(AIClient.makeError(status: 500, body: payload).isRateLimit)
    }
}

final class ErrorTests: XCTestCase {
    func testStatusCodes() {
        XCTAssertTrue(AIClient.makeError(status: 429, body: "").isRateLimit)
        if case .invalidKey = AIClient.makeError(status: 401, body: "") {} else { XCTFail("401 sollte invalidKey sein") }
        if case .http(500, _) = AIClient.makeError(status: 500, body: "kaputt") {} else { XCTFail("500 sollte http sein") }
    }

    func testMessageFormats() {
        XCTAssertEqual(AIClient.errorMessage(from: #"{"error":{"message":"Bad key"}}"#), "Bad key")
        XCTAssertEqual(AIClient.errorMessage(from: #"[{"error":{"code":400,"message":"API key not valid"}}]"#), "API key not valid")
        XCTAssertEqual(AIClient.errorMessage(from: "nur Text"), "nur Text")
    }

    func testQuotaMessageCountsAsRateLimit() {
        XCTAssertTrue(AIClient.makeError(status: 400, body: #"{"error":{"message":"Quota exceeded for model"}}"#).isRateLimit)
    }

    func testGermanDescriptions() {
        XCTAssertTrue(AIError.missingKey("Google Gemini").errorDescription!.contains("Einstellungen"))
    }
}

final class RequestTests: XCTestCase {
    func testRequestBodyWithImage() throws {
        let config = AIConfig(provider: .openrouter, model: "openrouter/free", key: "sk-test")
        let request = try AIClient.makeRequest(
            messages: [AIMessage(role: "system", text: "Regeln"), AIMessage(role: "user", text: "Lös das", images: ["QUJD"])],
            config: config)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "FreeNotes")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "openrouter/free")
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["content"] as? String, "Regeln")
        let parts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        let image = try XCTUnwrap(parts[1]["image_url"] as? [String: Any])
        XCTAssertEqual(image["url"] as? String, "data:image/jpeg;base64,QUJD")
    }

    func testGeminiEndpoint() throws {
        let config = AIConfig(provider: .gemini, model: AIProviderKind.gemini.defaultModel, key: "k")
        let request = try AIClient.makeRequest(messages: [AIMessage(role: "user", text: "Hi")], config: config)
        XCTAssertEqual(request.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Title"))
    }
}

final class LatexLiteTests: XCTestCase {
    func testFractionsRootsAndPowers() {
        XCTAssertEqual(LatexLite.clean(#"$\frac{1}{2}$"#), "(1)/(2)")
        XCTAssertEqual(LatexLite.clean(#"$\sqrt{16} = 4$"#), "√(16) = 4")
        XCTAssertEqual(LatexLite.clean("$x^2 + y^{10}$"), "x² + y¹⁰")
        XCTAssertEqual(LatexLite.clean("$x_1 = 2$"), "x₁ = 2")
    }

    func testOperatorsAndDelimiters() {
        XCTAssertEqual(LatexLite.clean(#"$$2 \cdot 3 \leq 7$$"#), "2 · 3 ≤ 7")
        XCTAssertEqual(LatexLite.clean(#"\left( a \right) \Rightarrow b"#), "( a ) ⇒ b")
        XCTAssertEqual(LatexLite.clean(#"x = \pm \sqrt{4}"#), "x = ± √(4)")
    }

    func testKeepsPlainTextAndUnknownScripts() {
        XCTAssertEqual(LatexLite.clean("Kosten: 5 Euro"), "Kosten: 5 Euro")
        XCTAssertEqual(LatexLite.clean("$a^{b}$"), "a^{b}")
    }

    func testDetectsMath() {
        XCTAssertTrue(LatexLite.containsMath("Es gilt $x^2$"))
        XCTAssertTrue(LatexLite.containsMath(#"\frac{a}{b}"#))
        XCTAssertFalse(LatexLite.containsMath("Nur Text"))
    }
}

final class ModelTests: XCTestCase {
    func testLibraryRoundTrip() throws {
        let page = Page(paper: .grid, items: [PageImageItem(asset: "a.jpg", frame: CGRect(x: 1, y: 2, width: 3, height: 4))])
        let nb = Notebook(title: "Mathe", subjectID: nil, colorIndex: 2, paper: .grid, pages: [page])
        let lib = LibraryData(subjects: [Subject(name: "Mathe", colorIndex: 0, symbol: "function")], notebooks: [nb])
        let decoded = try JSONDecoder().decode(LibraryData.self, from: JSONEncoder().encode(lib))
        XCTAssertEqual(decoded.notebooks, lib.notebooks)
        XCTAssertEqual(decoded.subjects, lib.subjects)
    }

    func testOldFilesWithoutNewFieldsStillLoad() throws {
        let nb = Notebook(title: "Alt", subjectID: nil, colorIndex: 0, paper: .lined, pages: [Page(paper: .lined)])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(nb)) as? [String: Any])
        json.removeValue(forKey: "lastPage")
        json.removeValue(forKey: "searchText")
        let decoded = try JSONDecoder().decode(Notebook.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.title, "Alt")
        XCTAssertNil(decoded.lastPage)
    }

    func testA4Proportions() {
        XCTAssertEqual(Page.defaultHeight / Page.defaultWidth, 1.414, accuracy: 0.001)
    }
}

final class PromptTests: XCTestCase {
    func testSystemPromptContainsContext() {
        let prompt = PromptBuilder.system(grade: "Klasse 9", subject: "Mathe")
        XCTAssertTrue(prompt.contains("Klasse 9"))
        XCTAssertTrue(prompt.contains("Fach: Mathe"))
        XCTAssertTrue(prompt.contains("LaTeX"))
    }

    func testEveryQuickActionHasAPrompt() {
        for action in QuickAction.allCases {
            XCTAssertFalse(action.prompt.isEmpty)
            XCTAssertFalse(action.title.isEmpty)
        }
    }
}

final class ImageItemTests: XCTestCase {
    func testOldItemsWithoutRotationLoad() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","asset":"a.jpg","frame":[[10,20],[100,50]]}"#
        let item = try JSONDecoder().decode(PageImageItem.self, from: Data(json.utf8))
        XCTAssertNil(item.rotation)
        XCTAssertEqual(item.angle, 0)
    }

    func testHitTestRespectsRotation() {
        var item = PageImageItem(asset: "a.jpg", frame: CGRect(x: 0, y: 0, width: 200, height: 20))
        XCTAssertTrue(item.contains(CGPoint(x: 190, y: 10)))
        XCTAssertFalse(item.contains(CGPoint(x: 100, y: 90)))
        item.rotation = Double.pi / 2
        // Um 90° gedreht steht das Bild senkrecht um den Mittelpunkt (100, 10)
        XCTAssertFalse(item.contains(CGPoint(x: 190, y: 10)))
        XCTAssertTrue(item.contains(CGPoint(x: 100, y: 90)))
        XCTAssertEqual(item.boundingBox.width, 20, accuracy: 0.001)
        XCTAssertEqual(item.boundingBox.height, 200, accuracy: 0.001)
    }

    func testCentimeters() {
        XCTAssertEqual(PageMetrics.centimeters(CGFloat(Page.defaultWidth)), 21, accuracy: 0.0001)
    }
}

final class PageDetectionTests: XCTestCase {
    /// Dunkler Hintergrund, helle Kopfleiste über die ganze Breite, darunter eine helle Seite.
    private func screenshot(width: Int, height: Int, page: (x: Range<Int>, y: Range<Int>), header: Range<Int>) -> [Double] {
        var lum = [Double](repeating: 0.25, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                if header.contains(y) || (page.x.contains(x) && page.y.contains(y)) {
                    lum[y * width + x] = 0.97
                }
            }
        }
        // ein paar dunkle »Textzeilen« auf der Seite
        for y in stride(from: page.y.lowerBound + 5, to: page.y.upperBound - 3, by: 9) {
            for x in page.x.dropFirst(5).dropLast(5) { lum[y * width + x] = 0.1 }
        }
        return lum
    }

    func testFindsSinglePageBelowHeader() throws {
        let lum = screenshot(width: 100, height: 140, page: (10..<90, 25..<130), header: 0..<20)
        let found = try XCTUnwrap(PageDetection.pageRect(luminance: lum, width: 100, height: 140))
        XCTAssertEqual(found.x, 10..<90)
        XCTAssertEqual(found.y, 25..<130)
        XCTAssertFalse(PageDetection.isSpread(width: Double(found.x.count), height: Double(found.y.count)))
    }

    func testBridgesGutterOfDoubleSpread() throws {
        var lum = screenshot(width: 200, height: 120, page: (10..<190, 20..<110), header: 0..<12)
        for y in 20..<110 { lum[y * 200 + 100] = 0.3 }   // Schatten in der Buchmitte
        let found = try XCTUnwrap(PageDetection.pageRect(luminance: lum, width: 200, height: 120))
        XCTAssertEqual(found.x, 10..<190)
        XCTAssertTrue(PageDetection.isSpread(width: Double(found.x.count), height: Double(found.y.count)))
    }

    func testRunHelper() {
        XCTAssertEqual(PageDetection.run(in: [0, 1, 1, 0, 1, 1, 0, 0, 0, 1], threshold: 0.5, center: 2, maxGap: 1), 1..<6)
        XCTAssertNil(PageDetection.run(in: [], threshold: 0.5, center: 0, maxGap: 1))
    }
}
