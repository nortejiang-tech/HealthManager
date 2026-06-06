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
    /// Local providers (Tailscale / loopback) may have no API key — pass `""` in that case.
    init?(fromConfig: Bool = true) {
        guard LLMConfig.isConfigured else { return nil }
        let key = LLMConfig.textApiKey ?? ""
        self.init(baseURL: LLMConfig.baseURL, model: LLMConfig.textModel, apiKey: key)
    }

    /// Same as `fromConfig`, but uses the vision model + vision endpoint's own key.
    /// Returns nil if vision not configured.
    static func visionClient() -> LLMClient? {
        guard LLMConfig.isVisionConfigured else { return nil }
        let key = LLMConfig.visionApiKey ?? ""
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

    struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct ResMessage: Decodable {
                let role: String?
                // Thinking models (qwen3-vl, deepseek-r1, …) may leave `content` null and
                // put the text under `reasoning_content` / `reasoning`. All optional so a
                // null `content` no longer fails the whole decode.
                let content: String?
                let reasoningContent: String?
                let reasoning: String?

                enum CodingKeys: String, CodingKey {
                    case role, content, reasoning
                    case reasoningContent = "reasoning_content"
                }
            }
            let message: ResMessage
        }
        let choices: [Choice]
    }

    /// Pull the assistant's usable text out of a chat-completions response body.
    /// Tolerates thinking-model shapes: null `content` → falls back to `reasoning_content`
    /// / `reasoning`, and strips any inline `<think>…</think>` reasoning so summaries read
    /// as clean prose. Throws `noContent` if nothing usable remains.
    static func extractContent(from data: Data) throws -> String {
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let msg = decoded.choices.first?.message
        let raw: String = {
            if let c = msg?.content, !c.isEmpty { return c }
            if let r = msg?.reasoningContent, !r.isEmpty { return r }
            if let r = msg?.reasoning, !r.isEmpty { return r }
            return ""
        }()
        let cleaned = stripThinkBlocks(raw)
        guard !cleaned.isEmpty else { throw LLMError.noContent }
        return cleaned
    }

    /// Remove `<think>…</think>` (and `<thinking>` / `<reasoning>`) reasoning blocks that
    /// some models emit inline before their final answer.
    static func stripThinkBlocks(_ input: String) -> String {
        var s = input
        for (open, close) in [("<think>", "</think>"), ("<thinking>", "</thinking>"), ("<reasoning>", "</reasoning>")] {
            while let openRange = s.range(of: open, options: .caseInsensitive) {
                if let closeRange = s.range(of: close, options: .caseInsensitive,
                                            range: openRange.upperBound..<s.endIndex) {
                    s.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                } else {
                    // Unclosed opening tag — drop just the tag, keep whatever follows.
                    s.removeSubrange(openRange)
                    break
                }
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum LLMError: LocalizedError {
        case invalidURL
        case imageEncodingFailed
        case httpStatus(Int, String)
        case decode(String)
        case noContent

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Base URL 无效。"
            case .imageEncodingFailed: return "图片编码失败，无法发送给视觉模型。"
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
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        // Local thinking models (qwen3-vl-30b etc.) can spend a while in <think> before
        // emitting the answer; 60s was occasionally too tight.
        req.timeoutInterval = 120
        req.httpBody = body

        // Retry transient connection drops. A local server over LAN/Tailscale frequently
        // produces NSURLErrorNetworkConnectionLost (-1005): iOS reuses a pooled TCP socket
        // the server already closed. These fail fast, so a couple of quick retries (fresh
        // socket) recover transparently instead of surfacing "网络连接已断开" to the user.
        let (data, response): (Data, URLResponse) = try await {
            var lastError: Error = LLMError.httpStatus(0, "no response")
            let maxAttempts = 3
            for attempt in 1...maxAttempts {
                do {
                    return try await session.data(for: req)
                } catch let e as URLError where Self.isTransientNetworkError(e) {
                    lastError = e
                    if attempt < maxAttempts {
                        // short backoff: 0.4s, 0.8s
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000)
                    }
                }
            }
            throw lastError
        }()

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.httpStatus(0, "no HTTPURLResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(500).description ?? ""
            throw LLMError.httpStatus(http.statusCode, snippet)
        }

        do {
            return try LLMClient.extractContent(from: data)
        } catch let e as LLMError {
            throw e
        } catch {
            let snippet = String(data: data, encoding: .utf8)?.prefix(500).description ?? ""
            throw LLMError.decode("\(error.localizedDescription) | body: \(snippet)")
        }
    }

    /// Transient, worth-retrying network failures. Deliberately excludes `.timedOut`
    /// (already waited the full 120s — retrying would triple the wait) and auth/HTTP errors.
    static func isTransientNetworkError(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost,    // -1005, the keep-alive reuse race
             .cannotConnectToHost,      // server briefly not accepting
             .secureConnectionFailed,   // TLS handshake blip (Tailscale HTTPS)
             .cannotFindHost,
             .dnsLookupFailed:
            return true
        default:
            return false
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
            throw LLMError.imageEncodingFailed
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
    /// plain-language Chinese, weight-management focused, actionable, no diagnostics.
    static let summarySystemPrompt: String = """
    你是一名体重管理教练。基于用户提供的本地聚合摘要（不含原始样本），用 80–120 字中文给出**针对体重管理的指导意见**，而不是复述数据：
    - 核心围绕能量平衡：摄入 vs 消耗（活动能量 + 基础代谢）、热量缺口/盈余、以及体重变化趋势是否与缺口一致；
    - 蛋白质摄入是否足够（保肌减脂）、是否需要调整进食或活动量；
    - 必须给出 1–2 条**今天/本周就能照做的具体行动**（例如「再多走 2000 步」「晚餐减少约 200 kcal 主食」「把蛋白质提到  XX g」），给出大致数字而非空泛建议；
    - 不要逐条罗列原始数字，不要做医疗诊断；若出现明显异常（如体重骤变、静息心率异常）提示「建议咨询医生」。
    - 直接输出正文，不要重复用户原文，不要使用「根据数据」这类开场白。
    """
}
