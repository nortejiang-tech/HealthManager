import Foundation

enum BriefLLMError: Error { case invalidOutput, timeout, server, httpStatus(Int), evidenceMismatch }
struct BriefLLMResponse: Sendable {
    let content: Data
    let inputTokens: Int?
    let outputTokens: Int?
    let finishReason: String?
    var attemptCount: Int = 1
}

extension LLMClient {
    static func canRetryHealthBrief(_ error: Error) -> Bool {
        if let e = error as? BriefLLMError {
            switch e { case .timeout: return true; case .httpStatus(let code): return (500..<600).contains(code); default: return false }
        }
        if let e = error as? URLError {
            return [.timedOut,.networkConnectionLost,.cannotConnectToHost,.cannotFindHost,.dnsLookupFailed].contains(e.code)
        }
        return false
    }
    /// Dedicated, bounded request. Does not inherit the report client's 120s retry loop.
    func completeHealthBrief(snapshot: HealthBriefSnapshot, budget: TimeInterval = 20) async throws -> BriefLLMResponse {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else { throw BriefLLMError.server }
        let system = """
        你是健康速报的谨慎文字编辑。输入仅为本机聚合事实，不是诊断或训练处方。
        只输出JSON，不要Markdown。结构：{"snapshot_id":"原id","state":"allowedStates中的一个","headline":"不超过16字","summary":"不超过60字","factors":[{"fact_ids":["输入中有数值的fact id"],"direction":"positive/negative/neutral","text":"不超过40字"}],"focus":"conserve/routine/observe","limitations":["限制"]}。
        factors最多三项；不添加事实、数字、疾病、用药、确定性承诺或新评分。所有自然语言字段禁止数字，数值由本地界面呈现。
        state必须在allowedStates中。如果defaultState为baseline或limited，headline必须等于对应状态中文标题（基线建立中／参考有限），summary必须原样使用localSummary，focus必须observe，所有factor的direction必须neutral。基线建立中不评价HRV高低或恢复好坏；参考有限不做恢复结论。steady不得conserve，caution不得routine。
        睡眠、HRV与Body Battery相关，不可独立投票。Body Battery是分段观测，不是实时测量。训练缺测不等于休息，负荷不全不可宣称低负荷。
        结合近三天、七天和二十八天已记录训练背景，列出证据与限制；无基线不以人群阈值判断HRV。
        """
        let encoded = try JSONEncoder().encode(snapshot)
        var body: [String: Any] = ["model": model, "temperature": 0.2, "stream": false,
            "max_tokens": 900, "messages": [["role":"system","content":system],
                ["role":"user","content":String(decoding: encoded, as: UTF8.self)]]]
        if model.lowercased().contains("minimax-m3.1") {
            body.removeValue(forKey: "max_tokens")
            body.removeValue(forKey: "temperature")
            body["max_completion_tokens"] = 4096
            body["reasoning_effort"] = "low"
            body["reasoning_split"] = true
        }
        let boundedBudget = min(55, max(3, budget))
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = boundedBudget - 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let stableRequest = request
        let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await session.data(for: stableRequest) }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(boundedBudget * 1_000_000_000)); throw BriefLLMError.timeout }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        guard let http = response as? HTTPURLResponse else { throw BriefLLMError.server }
        guard (200..<300).contains(http.statusCode) else { throw BriefLLMError.httpStatus(http.statusCode) }
        let parsed = try BriefResponseParser.parse(data)
        return BriefLLMResponse(content: parsed.content, inputTokens: parsed.inputTokens,
            outputTokens: parsed.outputTokens, finishReason: parsed.finishReason)
    }
}
