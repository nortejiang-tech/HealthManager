import Foundation
import UIKit

/// OpenAI-compatible Chat Completions client (POST `{baseURL}/chat/completions`).
///
/// Designed for the cluster of Chinese providers that mirror OpenAI's wire format
/// (DeepSeek / Doubao / Qwen / GLM / Moonshot). Non-streaming for simplicity — the
/// daily/weekly summary is short enough that 1-shot is fine; if latency becomes an
/// issue, swap to SSE later.
///
/// Health data privacy: the only payload we send is the already-aggregated
/// `daily_summaries.summary_text` (or weekly), prefixed by a Chinese system prompt
/// asking for plain-language analysis. Raw samples never leave the device.
struct LLMClient {

    let baseURL: String
    let model: String
    let apiKey: String
    let session: URLSession

    init(
        baseURL: String,
        model: String,
        apiKey: String,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.session = session
    }

    /// Convenience init that reads from `LLMConfig`. Returns nil if text-model not configured.
    init?(fromConfig: Bool = true) {
        guard LLMConfig.isConfigured,
              let key = LLMConfig.textApiKey else { return nil }
        self.init(baseURL: LLMConfig.baseURL, model: LLMConfig.textModel, apiKey: key)
    }

    /// Same as `fromConfig`, but uses the vision model + vision endpoint's own key.
    /// Returns nil if vision not configured.
    static func visionClient() -> LLMClient? {
        guard LLMConfig.isVisionConfigured,
              let key = LLMConfig.visionApiKey else { return nil }
        return LLMClient(baseURL: LLMConfig.resolvedVisionBaseURL, model: LLMConfig.visionModel, apiKey: key)
    }

    // MARK: - Request / Response shapes

    struct Message: Codable, Equatable {
        let role: String     // system | user | assistant
        let content: String
    }

    struct ChatRequest: Codable, Equatable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let stream: Bool

        init(model: String, messages: [Message], temperature: Double = 0.5) {
            self.model = model
            self.messages = messages
            self.temperature = temperature
            self.stream = false
        }
    }

    /// Multimodal content part for vision requests.
    /// Encodes to OpenAI-vision-compatible `{ type, text | image_url }`.
    enum ContentPart: Encodable, Equatable {
        case text(String)
        case imageDataURL(String)

        private enum CodingKeys: String, CodingKey { case type, text, image_url }
        private struct ImageURLObj: Encodable, Equatable {
            let url: String
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let s):
                try c.encode("text", forKey: .type)
                try c.encode(s, forKey: .text)
            case .imageDataURL(let url):
                try c.encode("image_url", forKey: .type)
                try c.encode(ImageURLObj(url: url), forKey: .image_url)
            }
        }
    }

    struct VisionMessage: Encodable, Equatable {
        let role: String
        let content: [ContentPart]
    }

    struct VisionRequest: Encodable, Equatable {
        let model: String
        let messages: [VisionMessage]
        let temperature: Double
        let stream: Bool

        init(model: String, messages: [VisionMessage], temperature: Double = 0.2) {
            self.model = model
            self.messages = messages
            self.temperature = temperature
            self.stream = false
        }
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct ResMessage: Decodable { let role: String; let content: String }
            let message: ResMessage
        }
        let choices: [Choice]
    }

    enum LLMError: LocalizedError {
        case invalidURL
        case httpStatus(Int, String)
        case decode(String)
        case noContent

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Base URL 无效。"
            case .httpStatus(let c, let body): return "LLM 服务返回 \(c)：\(body)"
            case .decode(let s): return "LLM 响应解析失败：\(s)"
            case .noContent: return "LLM 返回内容为空。"
            }
        }
    }

    /// Send a system + user message pair and return the assistant content.
    func complete(systemPrompt: String, user: String, temperature: Double = 0.5) async throws -> String {
        let payload = ChatRequest(
            model: model,
            messages: [
                Message(role: "system", content: systemPrompt),
                Message(role: "user", content: user)
            ],
            temperature: temperature
        )
        let body = try JSONEncoder().encode(payload)
        return try await send(body: body)
    }

    /// Send a pre-built request body. Internal entry point used by `complete` and tests.
    func send(body: Data) async throws -> String {
        let endpoint = baseURL.hasSuffix("/")
            ? baseURL + "chat/completions"
            : baseURL + "/chat/completions"
        guard let url = URL(string: endpoint) else { throw LLMError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.httpStatus(0, "no HTTPURLResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(500).description ?? ""
            throw LLMError.httpStatus(http.statusCode, snippet)
        }

        do {
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let content = decoded.choices.first?.message.content,
                  !content.isEmpty else {
                throw LLMError.noContent
            }
            return content
        } catch let e as LLMError {
            throw e
        } catch {
            let snippet = String(data: data, encoding: .utf8)?.prefix(500).description ?? ""
            throw LLMError.decode("\(error.localizedDescription) | body: \(snippet)")
        }
    }

    /// Analyze an image with a single text prompt. Returns the assistant's plain text.
    /// Downscales locally to keep token cost reasonable (vision models bill by image size).
    func analyzeImage(
        _ image: UIImage,
        prompt: String,
        systemPrompt: String? = nil,
        maxSide: CGFloat = 768,
        jpegQuality: CGFloat = 0.7,
        temperature: Double = 0.2
    ) async throws -> String {
        let resized = LLMClient.downscale(image, maxSide: maxSide)
        guard let jpeg = resized.jpegData(compressionQuality: jpegQuality) else {
            throw LLMError.invalidURL    // reuse — body shape invalid
        }
        let dataURL = "data:image/jpeg;base64," + jpeg.base64EncodedString()

        var messages: [VisionMessage] = []
        if let systemPrompt {
            // Some providers expect text-only system messages; ContentPart supports that.
            messages.append(VisionMessage(role: "system", content: [.text(systemPrompt)]))
        }
        messages.append(VisionMessage(role: "user", content: [
            .text(prompt),
            .imageDataURL(dataURL)
        ]))
        let payload = VisionRequest(model: model, messages: messages, temperature: temperature)
        let body = try JSONEncoder().encode(payload)
        return try await send(body: body)
    }

    /// Image down-scaler. Bottlenecks the long side so vision-model token cost
    /// scales reasonably. Returns the original if it's already within the bound.
    static func downscale(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let longSide = max(image.size.width, image.size.height)
        guard longSide > maxSide else { return image }
        let scale = maxSide / longSide
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    /// Shared system prompt for health summary analysis. Constrains the model to
    /// plain-language Chinese, ≤120 字, no diagnostic claims.
    static let summarySystemPrompt: String = """
    你是一名健康数据助手。基于用户提供的本地聚合摘要（不含原始样本），用 80–120 字写出 1 段中文分析：
    - 指出趋势 / 异常（步数、心率、体重、睡眠、饮食、用药）；
    - 给 1 条可执行建议；
    - 不要做医疗诊断，遇到风险点建议「咨询医生」。
    - 直接输出正文，不要重复用户原文。
    """
}
