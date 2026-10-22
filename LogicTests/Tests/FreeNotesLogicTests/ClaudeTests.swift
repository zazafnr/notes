import XCTest
@testable import FreeNotesLogic

final class ClaudeRequestTests: XCTestCase {
    private let config = AIConfig(provider: .claude, model: "claude-sonnet-5-5", key: "sk-ant-test")

    func testRequestShape() throws {
        let request = try ClaudeClient.makeRequest(
            messages: [
                AIMessage(role: "system", text: "Regeln"),
                AIMessage(role: "user", text: "Lös das", images: ["QUJD"]),
            ],
            config: config, effort: "medium")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual(body["system"] as? String, "Regeln")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, ClaudeClient.maxTokens)
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["temperature"])

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        let blocks = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks[0]["type"] as? String, "image")
        let source = try XCTUnwrap(blocks[0]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, "QUJD")
        XCTAssertEqual(blocks[1]["text"] as? String, "Lös das")
    }

    func testHaikuHasNoServerFallback() throws {
        let haiku = AIConfig(provider: .claude, model: "claude-haiku-5-5", key: "k")
        let request = try ClaudeClient.makeRequest(messages: [AIMessage(role: "user", text: "Hi")], config: haiku, effort: "low")
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-beta"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(body["fallbacks"])
    }

    func testConversationStartsWithUserAndMergesRoles() {
        let turns = ClaudeClient.conversation([
            AIMessage(role: "assistant", text: "Hallo"),
            AIMessage(role: "user", text: "A"),
            AIMessage(role: "user", text: "B"),
            AIMessage(role: "assistant", text: "C"),
            AIMessage(role: "user", text: ""),
        ])
        XCTAssertEqual(turns.map { $0["role"] as? String }, ["user", "assistant"])
        XCTAssertEqual((turns[0]["content"] as? [[String: Any]])?.count, 2)
    }
}

final class ClaudeStreamTests: XCTestCase {
    func testEvents() {
        XCTAssertEqual(ClaudeClient.parseEvents(#"data: {"type":"message_start","message":{"usage":{"input_tokens":1200,"cache_read_input_tokens":100,"output_tokens":3}}}"#),
                       [.usage(input: 1300, output: 3)])
        XCTAssertEqual(ClaudeClient.parseEvents(#"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"x = 2"}}"#),
                       [.text("x = 2")])
        XCTAssertEqual(ClaudeClient.parseEvents(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#), [])
        XCTAssertEqual(ClaudeClient.parseEvents(#"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":812}}"#),
                       [.usage(input: nil, output: 812), .stop("end_turn")])
        XCTAssertEqual(ClaudeClient.parseEvents("event: ping"), [])
        guard case .error = ClaudeClient.parseEvents(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#).first else {
            return XCTFail("Fehler nicht erkannt")
        }
    }

    func testClaudeErrorsAllowFallback() {
        XCTAssertTrue(AIClient.makeError(status: 529, body: #"{"type":"error","error":{"message":"Overloaded"}}"#).isRateLimit)
        XCTAssertTrue(AIClient.makeError(status: 400, body: #"{"type":"error","error":{"message":"Your credit balance is too low"}}"#).isRateLimit)
    }
}

final class ClaudePricingTests: XCTestCase {
    func testPricing() {
        XCTAssertEqual(ClaudePricing.cost(model: "claude-sonnet-5-5", inputTokens: 1_000_000, outputTokens: 0), 2, accuracy: 0.0001)
        XCTAssertEqual(ClaudePricing.cost(model: "claude-sonnet-5-5", inputTokens: 1500, outputTokens: 1500), 0.018, accuracy: 0.0001)
        XCTAssertEqual(ClaudePricing.cost(model: "claude-haiku-5-5", inputTokens: 1500, outputTokens: 1500), 0.0009, accuracy: 0.00001)
        // Unbekannt = teuerster Preis
        XCTAssertEqual(ClaudePricing.cost(model: "claude-neu", inputTokens: 0, outputTokens: 1_000_000), 20, accuracy: 0.0001)
    }
}
