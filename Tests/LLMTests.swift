import XCTest
@testable import HealthManager

final class LLMTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LLMConfig.reset()
        LLMConfig.customPresets = []
    }

    override func tearDown() {
        LLMConfig.reset()
        LLMConfig.customPresets = []
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
        LLMConfig.visionBaseURL = "https://vision.example.com/v1"
        LLMConfig.visionModel = "vision-x"
        XCTAssertFalse(LLMConfig.isVisionConfigured, "vision endpoint still has no key of its own")
        LLMConfig.setApiKey("vk", forBaseURL: "https://vision.example.com/v1")
        XCTAssertTrue(LLMConfig.isVisionConfigured)
        XCTAssertEqual(LLMConfig.resolvedVisionBaseURL, "https://vision.example.com/v1")
    }

    func test_config_visionBaseURL_fallsBackToTextBaseURL() {
        LLMConfig.baseURL = "https://api.example.com/v1"
        LLMConfig.visionBaseURL = ""
        XCTAssertEqual(LLMConfig.resolvedVisionBaseURL, "https://api.example.com/v1")
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
        LLMConfig.visionBaseURL = "vx"
        LLMConfig.textModel = "y"
        LLMConfig.visionModel = "vy"
        LLMConfig.apiKey = "z"
        LLMConfig.reset()
        XCTAssertTrue(LLMConfig.enabled, "reset should restore default-on")
        XCTAssertEqual(LLMConfig.baseURL, "")
        XCTAssertEqual(LLMConfig.visionBaseURL, "")
        XCTAssertEqual(LLMConfig.textModel, "")
        XCTAssertEqual(LLMConfig.visionModel, "")
        XCTAssertNil(LLMConfig.apiKey)
    }

    func test_config_presetsCoverExpectedVendors() {
        let names = LLMConfig.presets.map(\.name)
        XCTAssertTrue(names.contains("DeepSeek"))
        XCTAssertTrue(names.contains { $0.contains("Doubao") || $0.contains("豆包") })
        XCTAssertTrue(names.contains { $0.contains("Qwen") || $0.contains("千问") })
        XCTAssertTrue(names.contains("Ollama Cloud"))
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
        LLMConfig.visionBaseURL = "https://vision.example.com/v1"
        LLMConfig.textModel = "abc"
        LLMConfig.visionModel = "vision"
        LLMConfig.apiKey = "sk-x"
        LLMConfig.setApiKey("sk-vision", forBaseURL: "https://vision.example.com/v1")
        let v = LLMClient.visionClient()
        XCTAssertNotNil(v)
        XCTAssertEqual(v?.model, "vision")
        XCTAssertEqual(v?.baseURL, "https://vision.example.com/v1")
        XCTAssertEqual(v?.apiKey, "sk-vision", "vision client uses the vision endpoint's own key")
    }

    // MARK: - Per-provider key memory + custom presets

    func test_perProviderKeyMemory_isIndependentPerEndpoint() {
        LLMConfig.setApiKey("key-a", forBaseURL: "https://a.example.com/v1")
        LLMConfig.setApiKey("key-b", forBaseURL: "https://b.example.com/v1/")
        XCTAssertEqual(LLMConfig.apiKey(forBaseURL: "https://a.example.com/v1"), "key-a")
        // Trailing slash is normalized away, so both forms resolve to the same entry.
        XCTAssertEqual(LLMConfig.apiKey(forBaseURL: "https://b.example.com/v1"), "key-b")
        LLMConfig.setApiKey(nil, forBaseURL: "https://a.example.com/v1")
        XCTAssertNil(LLMConfig.apiKey(forBaseURL: "https://a.example.com/v1"))
        XCTAssertEqual(LLMConfig.apiKey(forBaseURL: "https://b.example.com/v1"), "key-b")
    }

    func test_googleGeminiPreset_isPresentAndFree() {
        let google = LLMConfig.presets.first { $0.name.contains("Gemini") }
        XCTAssertNotNil(google, "Google Gemini preset should ship as an option")
        XCTAssertFalse(google?.suggestedTextModel.isEmpty ?? true)
    }

    func test_customPreset_addAppearsInListAndRemoves() {
        let p = LLMConfig.Preset(name: "我的接口", baseURL: "https://my.example.com/v1",
                                 suggestedTextModel: "m-text", suggestedVisionModel: "")
        LLMConfig.addCustomPreset(p)
        XCTAssertTrue(LLMConfig.presets.contains { $0.id == "我的接口" })
        XCTAssertTrue(LLMConfig.isCustomPreset(id: "我的接口"))
        XCTAssertFalse(LLMConfig.isCustomPreset(id: "DeepSeek"))
        LLMConfig.removeCustomPreset(id: "我的接口")
        XCTAssertFalse(LLMConfig.presets.contains { $0.id == "我的接口" })
    }

    func test_summarySystemPrompt_nonEmpty() {
        XCTAssertFalse(LLMClient.summarySystemPrompt.isEmpty)
        XCTAssertTrue(LLMClient.summarySystemPrompt.contains("健康"))
    }
}
