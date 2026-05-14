import XCTest
@testable import HealthManager

final class LLMTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LLMConfig.reset()
    }

    override func tearDown() {
        LLMConfig.reset()
        super.tearDown()
    }

    // MARK: - LLMConfig

    func test_config_defaultsEnabledIsTrue() {
        XCTAssertTrue(LLMConfig.enabled, "AI summary should default to enabled per product policy")
    }

    func test_config_isConfigured_falseWithoutKey() {
        LLMConfig.baseURL = "https://api.example.com/v1"
        LLMConfig.textModel = "test-model"
        XCTAssertFalse(LLMConfig.isConfigured, "missing key → not configured")
    }

    func test_config_isConfigured_trueWithFullTriple() {
        LLMConfig.baseURL = "https://api.example.com/v1"
        LLMConfig.textModel = "test-model"
        LLMConfig.apiKey = "sk-test-12345"
        XCTAssertTrue(LLMConfig.isConfigured)
    }

    func test_config_visionConfigured_separate() {
        LLMConfig.baseURL = "https://api.example.com/v1"
        LLMConfig.textModel = "text-x"
        LLMConfig.apiKey = "k"
        XCTAssertTrue(LLMConfig.isConfigured)
        XCTAssertFalse(LLMConfig.isVisionConfigured, "text alone is not enough for vision")
        LLMConfig.visionModel = "vision-x"
        XCTAssertTrue(LLMConfig.isVisionConfigured)
    }

    func test_config_modelLegacyAliasMapsToTextModel() {
        LLMConfig.model = "old-call-site"
        XCTAssertEqual(LLMConfig.textModel, "old-call-site")
    }

    func test_config_apiKey_roundTrip_viaKeychain() {
        LLMConfig.apiKey = "sk-secret-aaaabbbbcccc"
        XCTAssertEqual(LLMConfig.apiKey, "sk-secret-aaaabbbbcccc")
    }

    func test_config_apiKey_nilClearsKeychain() {
        LLMConfig.apiKey = "to-be-cleared"
        XCTAssertNotNil(LLMConfig.apiKey)
        LLMConfig.apiKey = nil
        XCTAssertNil(LLMConfig.apiKey)
    }

    func test_config_reset_clearsEverything() {
        LLMConfig.enabled = false
        LLMConfig.baseURL = "x"
        LLMConfig.textModel = "y"
        LLMConfig.visionModel = "vy"
        LLMConfig.apiKey = "z"
        LLMConfig.reset()
        XCTAssertTrue(LLMConfig.enabled, "reset should restore default-on")
        XCTAssertEqual(LLMConfig.baseURL, "")
        XCTAssertEqual(LLMConfig.textModel, "")
        XCTAssertEqual(LLMConfig.visionModel, "")
        XCTAssertNil(LLMConfig.apiKey)
    }

    func test_config_presetsCoverExpectedVendors() {
        let names = LLMConfig.presets.map(\.name)
        XCTAssertTrue(names.contains("DeepSeek"))
        XCTAssertTrue(names.contains { $0.contains("Doubao") || $0.contains("豆包") })
        XCTAssertTrue(names.contains { $0.contains("Qwen") || $0.contains("千问") })
    }

    // MARK: - LLMClient request shape

    func test_chatRequest_encodesExpectedFields() throws {
        let req = LLMClient.ChatRequest(
            model: "deepseek-chat",
            messages: [
                LLMClient.Message(role: "system", content: "你是 X。"),
                LLMClient.Message(role: "user", content: "ping")
            ],
            temperature: 0.3
        )
        let data = try JSONEncoder().encode(req)
        let str = String(data: data, encoding: .utf8)!
        XCTAssertTrue(str.contains("\"model\":\"deepseek-chat\""))
        XCTAssertTrue(str.contains("\"role\":\"system\""))
        XCTAssertTrue(str.contains("\"role\":\"user\""))
        XCTAssertTrue(str.contains("\"temperature\":0.3"))
        XCTAssertTrue(str.contains("\"stream\":false"))
    }

    func test_client_fromConfig_returnsNilWhenUnconfigured() {
        XCTAssertNil(LLMClient(fromConfig: true), "no config → nil client")
    }

    func test_client_fromConfig_returnsClientWhenConfigured() {
        LLMConfig.baseURL = "https://api.example.com/v1"
        LLMConfig.textModel = "abc"
        LLMConfig.apiKey = "sk-x"
        XCTAssertNotNil(LLMClient(fromConfig: true))
    }

    func test_visionClient_nilWithoutVisionModel() {
        LLMConfig.baseURL = "https://api.example.com/v1"
        LLMConfig.textModel = "abc"
        LLMConfig.apiKey = "sk-x"
        XCTAssertNil(LLMClient.visionClient())
    }

    func test_visionClient_returnsClientWhenAllConfigured() {
        LLMConfig.baseURL = "https://api.example.com/v1"
        LLMConfig.textModel = "abc"
        LLMConfig.visionModel = "vision"
        LLMConfig.apiKey = "sk-x"
        let v = LLMClient.visionClient()
        XCTAssertNotNil(v)
        XCTAssertEqual(v?.model, "vision")
    }

    func test_summarySystemPrompt_nonEmpty() {
        XCTAssertFalse(LLMClient.summarySystemPrompt.isEmpty)
        XCTAssertTrue(LLMClient.summarySystemPrompt.contains("健康"))
    }
}
