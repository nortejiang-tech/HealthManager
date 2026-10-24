import Foundation
import Combine
import CryptoKit
import GRDB

@MainActor final class HealthBriefManager: ObservableObject {
    static let autoKey = "healthBrief.autoAI.v1"
    @Published private(set) var snapshot: HealthBriefSnapshot?
    @Published private(set) var narrative: BriefNarrative?
    @Published private(set) var isAnalyzing = false
    @Published private(set) var analysisStatus = "本地汇总 · AI 按需解读"
    @Published private(set) var trainingPending = true
    private let database: DatabaseManager
    private var refreshing = false
    private var refreshAgain = false
    private var pendingForceTraining = false
    private var training: TrainingSnapshot?
    private var trainingAt: Date?
    private var lastAutoID: String?
    private var publishedCacheKey: String?
    nonisolated private static func cacheKey(_ id: String, _ endpoint: String, _ model: String) -> String {
        let profile = SHA256.hash(data: Data((endpoint + "\n" + model).utf8)).map { String(format: "%02x", $0) }.joined()
        return id + ":" + profile
    }
    init(database: DatabaseManager) { self.database = database }

    func refresh(forceTraining: Bool = false) async {
        guard !refreshing else { refreshAgain = true; pendingForceTraining = pendingForceTraining || forceTraining; return }
        refreshing = true
        defer {
            refreshing = false
            if refreshAgain { refreshAgain = false; let force = pendingForceTraining; pendingForceTraining = false; Task { await self.refresh(forceTraining: force) } }
        }
        do {
            try await publishFacts()
            if forceTraining || trainingAt.map({ Date().timeIntervalSince($0) > 300 }) != false {
                trainingPending = true
                do {
                    training = try await TrainingSnapshotLoader.load(database: database)
                    trainingAt = Date()
                } catch { training = nil; analysisStatus = "训练背景未能更新 · 当前仅参考持续健康数据" }
                trainingPending = false
                try await publishFacts()
            }
            trainingPending = false
            if UserDefaults.standard.bool(forKey: Self.autoKey), lastAutoID != snapshot?.id {
                await analyze(manual: false)
            }
        } catch { analysisStatus = "健康速报读取失败，稍后刷新重试"; trainingPending = false }
    }

#if DEBUG
    private var didHandleDeveloperRetry = false
    /// Paired-device diagnostic action, explicitly authorized after the owner's failed click.
    /// No normal launch or preference enables this, and the process can consume it only once.
    func retryAuthorizedDeveloperRequestOnce() async {
        guard ProcessInfo.processInfo.arguments.contains("-HM_DEBUG_BRIEF_RETRY_ONCE"), !didHandleDeveloperRetry else { return }
        didHandleDeveloperRetry = true
        let deadline = Date().addingTimeInterval(45)
        while (refreshing || trainingPending || snapshot == nil), Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !refreshing, !trainingPending, snapshot != nil else { return }
        await analyze(manual: true)
    }
#endif

    private func publishFacts() async throws {
        let next = try await HealthBriefLoader.load(database: database, training: training)
        if next.id != snapshot?.id {
            snapshot = next; narrative = nil
            analysisStatus = UserDefaults.standard.bool(forKey: Self.autoKey) ? "数据已更新 · 等待新解读" : "本地汇总 · 可按需 AI 解读"
        }
        let cacheKey = Self.cacheKey(next.id, LLMConfig.baseURL, LLMConfig.textModel)
        if publishedCacheKey != cacheKey { narrative = nil; publishedCacheKey = cacheKey }
        let cached: String? = try await database.asyncRead { db in
            try String.fetchOne(db, sql: "SELECT narrative_json FROM health_brief_cache WHERE snapshot_id=? AND prompt_version=?", arguments: [cacheKey,HealthBriefLoader.promptVersion])
        }
        if let data = cached?.data(using: .utf8), let parsed = try? JSONDecoder().decode(BriefNarrative.self, from: data), HealthBriefRules.validate(narrative: parsed, for: next) {
            narrative = parsed; analysisStatus = "AI 辅助解读 · 已校验当前事实"
        }
    }

    @discardableResult
    func analyze(manual: Bool) async -> Bool {
        guard !isAnalyzing, let captured = snapshot else { return false }
        guard !trainingPending else { analysisStatus = "训练背景计算后可生成完整解读"; return false }
#if DEBUG && targetEnvironment(simulator)
        // UI-only deterministic fixture. Never compiled into the paired iPhone build.
        if ProcessInfo.processInfo.arguments.contains("-HM_UI_TEST_BRIEF_RESPONSE") {
            isAnalyzing = true
            defer { isAnalyzing = false }
            try? await Task.sleep(nanoseconds: 150_000_000)
            if ProcessInfo.processInfo.arguments.contains("-HM_UI_TEST_BRIEF_FAILURE") {
                narrative = nil
                analysisStatus = "AI 响应超时，可重试 · 本地汇总仍有效"
                return false
            }
            let proposal = BriefNarrative(snapshot_id: captured.id, state: captured.defaultState,
                headline: captured.defaultState.title, summary: captured.localSummary,
                factors: captured.facts.filter { $0.value?.isFinite == true }.prefix(3).map {
                    BriefFactor(fact_ids: [$0.id], direction: "neutral", text: "参考已记录的数据，继续观察。")
                }, focus: "observe", limitations: [])
            guard let prepared = HealthBriefGrounding.prepare(proposal, for: captured), snapshot?.id == captured.id else { return false }
            narrative = prepared.narrative
            analysisStatus = "AI 辅助解读 · 已校验当前事实"
            return true
        }
#endif
        guard LLMConfig.enabled, let client = LLMClient() else { analysisStatus = "请先在设置中配置并启用 AI 文本通道"; return false }
        if !manual {
            guard captured.defaultState != .limited else { return false }
            let attempts = (try? await database.asyncRead { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_brief_cache WHERE day=?", arguments: [captured.day]) ?? 0
            }) ?? 3
            let alreadyAttempted = (try? await database.asyncRead { db in
                try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM health_brief_cache WHERE snapshot_id=?)", arguments: [Self.cacheKey(captured.id, client.baseURL, client.model)]) ?? true
            }) ?? true
            guard !alreadyAttempted else { lastAutoID = captured.id; return false }
            guard attempts < 3 else { analysisStatus = "本日自动解读已达三次 · 可手动更新"; return false }
        }
        if narrative != nil && !manual { lastAutoID = captured.id; return false }
        isAnalyzing = true
        defer { isAnalyzing = false }
        let started = Date()
        let endpoint = client.baseURL, model = client.model
        let cacheKey = Self.cacheKey(captured.id, endpoint, model)
        lastAutoID = captured.id
        var lastResponse: BriefLLMResponse?
        // Record attempts before networking, including failures. Prevent request storms after relaunch.
        do {
            try await database.asyncWrite { db in
                try db.execute(sql: "INSERT OR REPLACE INTO health_brief_cache(snapshot_id,day,phase,model,prompt_version,generated_at) VALUES(?,?,?,?,?,?)",
                    arguments: [cacheKey,captured.day,captured.phase,model,HealthBriefLoader.promptVersion,Date().timeIntervalSince1970])
            }
            analysisStatus = "正在根据聚合事实生成解读…"
            var response: BriefLLMResponse
            do {
                response = try await client.completeHealthBrief(snapshot: captured)
            } catch {
                guard manual, LLMClient.canRetryHealthBrief(error) else { throw error }
                guard snapshot?.id == captured.id, LLMConfig.enabled,
                      LLMConfig.baseURL == endpoint, LLMConfig.textModel == model else { throw CancellationError() }
                analysisStatus = "模型响应较慢，正在重试一次 · 可继续浏览"
                response = try await client.completeHealthBrief(snapshot: captured, budget: 35)
                response.attemptCount = 2
            }
            lastResponse = response
            guard snapshot?.id == captured.id, LLMConfig.enabled,
                  LLMConfig.baseURL == endpoint, LLMConfig.textModel == model else {
                BriefAttemptDiagnostic.save(status: "discarded", category: "facts_or_profile_changed", model: model, snapshot: captured.id, started: started, response: response)
                analysisStatus = "数据或模型已更新，请重新生成解读"
                return false
            }
            let proposal = try JSONDecoder().decode(BriefNarrative.self, from: response.content)
            guard let grounded = HealthBriefGrounding.prepare(proposal, for: captured) else { throw BriefLLMError.evidenceMismatch }
            let parsed = grounded.narrative
            let json = String(decoding: try JSONEncoder().encode(parsed), as: UTF8.self)
            try await database.asyncWrite { db in
                try db.execute(sql: "UPDATE health_brief_cache SET narrative_json=?,input_tokens=?,output_tokens=? WHERE snapshot_id=?",
                    arguments: [json,response.inputTokens,response.outputTokens,cacheKey])
            }
            narrative = parsed; analysisStatus = "AI 辅助解读 · 已校验当前事实"
            BriefAttemptDiagnostic.save(status: "success", category: "validated", model: model, snapshot: captured.id, started: started, response: response, repairs: grounded.repairs)
            return true
        } catch {
            // Never retain the previous snapshot's interpretation or leak provider response/errors.
            let category = BriefAttemptDiagnostic.category(error)
            BriefAttemptDiagnostic.save(status: "failure", category: category, model: model, snapshot: captured.id, started: started, response: lastResponse)
            if snapshot?.id == captured.id { narrative = nil; analysisStatus = BriefAttemptDiagnostic.message(category) }
            return false
        }
    }
}
