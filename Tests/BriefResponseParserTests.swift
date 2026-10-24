import XCTest
@testable import HealthManager

final class BriefResponseParserTests: XCTestCase {
    func data(_ content:Any,finish:String="stop",usage:[String:Any]=[:]) throws -> Data {
        try JSONSerialization.data(withJSONObject:["choices":[["message":["content":content,"reasoning_content":"private reasoning"],"finish_reason":finish]],"usage":usage])
    }
    func testMiniMaxOutputLimitNeverUsesReasoningAsFinalAnswer() throws {
        XCTAssertThrowsError(try BriefResponseParser.parse(data("",finish:"length"))) { XCTAssertEqual($0 as? BriefResponseError,.outputLimit) }
        XCTAssertThrowsError(try BriefResponseParser.parse(data(NSNull()))) { XCTAssertEqual($0 as? BriefResponseError,.missingFinal) }
        XCTAssertThrowsError(try BriefResponseParser.parse(data("{\"summary\":",finish:"length"))) { XCTAssertEqual($0 as? BriefResponseError,.outputLimit) }
    }
    func testBalancedThinkingAndWholeJSONFenceSupported() throws {
        let p=try BriefResponseParser.parse(data("<THINK>思考，不展示</THINK>\n```json\n{\"note\":\"İ🙂\"}\n```"))
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:p.content) as? [String:String]);XCTAssertEqual(object["note"],"İ🙂")
        XCTAssertThrowsError(try BriefResponseParser.parse(data("<think>never closed {}")))
        XCTAssertThrowsError(try BriefResponseParser.parse(data("Some prose {\"x\":1}")))
        XCTAssertThrowsError(try BriefResponseParser.parse(data("[]")))
    }
    func testUsageCountsRejectBoolAndOverflowButAcceptOne() throws {
        let p=try BriefResponseParser.parse(data("{}",usage:["prompt_tokens":1,"completion_tokens":true]));XCTAssertEqual(p.inputTokens,1);XCTAssertNil(p.outputTokens)
        let q=try BriefResponseParser.parse(data("{}",usage:["prompt_tokens":Double.greatestFiniteMagnitude,"completion_tokens":1.25]));XCTAssertNil(q.inputTokens);XCTAssertNil(q.outputTokens)
        let r=try BriefResponseParser.parse(data("{}",usage:["prompt_tokens":-1,"completion_tokens":2]));XCTAssertNil(r.inputTokens);XCTAssertEqual(r.outputTokens,2)
    }
    func testProviderErrorCodeAndContentPartArray() throws {
        let d=try JSONSerialization.data(withJSONObject:["base_resp":["status_code":1004]])
        XCTAssertThrowsError(try BriefResponseParser.parse(d)) { XCTAssertEqual($0 as? BriefResponseError,.provider(1004)) }
        let p=try BriefResponseParser.parse(data([["type":"reasoning","text":"untrusted"],["type":"text","text":"{\"ok\":true}"]]))
        XCTAssertEqual(String(decoding:p.content,as:UTF8.self),"{\"ok\":true}")
    }
    func testOnlyTransientHealthBriefErrorsCanRetry() {
        XCTAssertTrue(LLMClient.canRetryHealthBrief(URLError(.timedOut)))
        XCTAssertTrue(LLMClient.canRetryHealthBrief(BriefLLMError.httpStatus(503)))
        for error in [BriefLLMError.httpStatus(401), .httpStatus(429), .evidenceMismatch, .invalidOutput] { XCTAssertFalse(LLMClient.canRetryHealthBrief(error)) }
        XCTAssertFalse(LLMClient.canRetryHealthBrief(BriefResponseError.outputLimit))
    }
    func testDiagnosticCategoriesExposeNoProviderContent() {
        XCTAssertEqual(BriefAttemptDiagnostic.category(BriefResponseError.outputLimit),"output_limit")
        XCTAssertEqual(BriefAttemptDiagnostic.category(BriefLLMError.httpStatus(401)),"http_401")
        XCTAssertEqual(BriefAttemptDiagnostic.category(BriefLLMError.evidenceMismatch),"evidence_validation")
        XCTAssertTrue(BriefAttemptDiagnostic.message("output_limit").contains("输出额度"))
    }
}
