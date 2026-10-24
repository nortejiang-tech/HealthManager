import Foundation

/// Safe local receipt: categories and usage only. Never provider text, keys or health facts.
struct BriefAttemptDiagnostic: Codable {
    let status: String
    let category: String
    let model: String
    let promptVersion: String
    let snapshotId: String
    let recordedAt: Date
    let elapsedMilliseconds: Int
    let inputTokens: Int?
    let outputTokens: Int?
    let finishReason: String?
    let repairs: [String]?
    let attemptCount: Int?

    static func save(status: String, category: String, model: String, snapshot: String,
                     started: Date, response: BriefLLMResponse? = nil, repairs: [String]? = nil) {
        let receipt = BriefAttemptDiagnostic(status: status, category: category, model: model,
            promptVersion: HealthBriefLoader.promptVersion, snapshotId: snapshot, recordedAt: Date(),
            elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(started) * 1000)),
            inputTokens: response?.inputTokens, outputTokens: response?.outputTokens,
            finishReason: response?.finishReason, repairs: repairs, attemptCount: response?.attemptCount)
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let data = try? JSONEncoder().encode(receipt) else { return }
        let url = root.appendingPathComponent("health-brief-last-attempt.json")
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func category(_ error: Error) -> String {
        if let e = error as? BriefLLMError {
            switch e {
            case .timeout: return "timeout"
            case .httpStatus(let code): return "http_\(code)"
            case .evidenceMismatch: return "evidence_validation"
            case .server: return "endpoint_configuration"
            case .invalidOutput: return "invalid_final_json"
            }
        }
        if let e = error as? BriefResponseError {
            switch e {
            case .outputLimit: return "output_limit"
            case .missingFinal: return "missing_final_answer"
            case .provider(let code): return "provider_\(code)"
            case .malformedEnvelope: return "invalid_response_format"
            }
        }
        if error is DecodingError { return "narrative_schema" }
        if let e = error as? URLError { return e.code == .timedOut ? "timeout" : (e.code == .cancelled ? "cancelled" : "network") }
        if error is CancellationError { return "cancelled" }
        return "local_processing"
    }
    static func message(_ category: String) -> String {
        switch category {
        case "timeout": return "AI 响应超时，可重试 · 本地汇总仍有效"
        case "output_limit": return "模型思考耗尽输出额度，未形成完整解读 · 本地汇总仍有效"
        case "missing_final_answer": return "模型未返回最终答案 · 本地汇总仍有效"
        case "http_401", "http_403": return "AI 接口认证失败，请检查设置中的 Key 或权限"
        case "http_429": return "AI 接口限流或额度不足，稍后重试"
        case "network": return "AI 网络连接失败，可重试 · 本地汇总仍有效"
        case "evidence_validation": return "AI 解读未通过事实校验 · 已保留本地判断"
        case "narrative_schema", "invalid_final_json", "invalid_response_format": return "模型未按约定格式返回 · 已保留本地判断"
        default: return "AI 暂不可用（\(category)）· 本地汇总仍有效"
        }
    }
}
