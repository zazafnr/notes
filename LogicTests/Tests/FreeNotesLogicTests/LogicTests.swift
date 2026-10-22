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
