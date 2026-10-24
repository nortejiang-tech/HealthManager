import Foundation
import Combine
import GRDB

@MainActor
final class GarminSyncManager: ObservableObject {
    @Published private(set) var isConfigured: Bool
    @Published private(set) var isSyncing = false
    @Published private(set) var status = "尚未连接"
    @Published private(set) var records: [GarminMetricRecord] = []
    @Published private(set) var lastError: String?
    @Published private(set) var nextAllowedRefresh = Date.distantPast {
        didSet { UserDefaults.standard.set(nextAllowedRefresh.timeIntervalSince1970,forKey:"garmin.cn.nextAllowedRefresh") }
    }
    private let database: DatabaseManager
    private let keyStore = GarminKeyStore()
    private let client: GarminClient
    private var lastAttempt = Date.distantPast
    private var generation = 0
    private var consecutiveFailures = 0
    var onDataChanged: (() -> Void)?

    init(database: DatabaseManager) {
        self.database = database
        client = GarminClient(credentials: GarminKeyStore())
        nextAllowedRefresh = Date(timeIntervalSince1970:UserDefaults.standard.double(forKey:"garmin.cn.nextAllowedRefresh"))
        lastAttempt = Date(timeIntervalSince1970:UserDefaults.standard.double(forKey:"garmin.cn.lastAttempt"))
        isConfigured = keyStore.isConfigured
        status = isConfigured ? "已保存中国区密钥，等待同步" : "尚未连接"
    }
    func importKey(_ key: String) async throws {
        guard !isSyncing else { throw GarminAPIError.operationInProgress }
        try keyStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
        generation += 1
        await client.invalidate()
        isConfigured = true; lastError = nil; lastAttempt = .distantPast; nextAllowedRefresh = .distantPast
        status = "密钥已保存，等待验证"
    }
    func disconnect() async throws {
        guard !isSyncing else { throw GarminAPIError.operationInProgress }
        try keyStore.remove(); generation += 1; await client.invalidate()
        isConfigured = false; status = "已断开，历史数据保留"; lastError = nil
    }
    func load() async {
        do {
            records = try await database.asyncRead { try GarminStore.records(db: $0, since: "2026-10-23") }
        } catch { lastError = "Garmin 本地数据读取失败" }
    }
    func refresh(force: Bool = false, days: Int = 3, now: Date = Date()) async {
        await load()
        guard isConfigured, !isSyncing, now >= nextAllowedRefresh,
              force || now.timeIntervalSince(lastAttempt) >= 15 * 60 else { return }
        isSyncing = true; lastAttempt = now; UserDefaults.standard.set(now.timeIntervalSince1970,forKey:"garmin.cn.lastAttempt"); lastError = nil; status = "正在同步中国区数据…"
        let epoch = generation
        defer { isSyncing = false }
        let calendar = Calendar.current
        let count = records.isEmpty ? 28 : min(28, max(1, days))
        var failures = 0
        outer: for back in 0..<count {
            guard let day = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            let date = TrainingCalculator.dayKey(day, calendar)
            // Preserve earlier historical projections; this integration starts on the agreed day.
            guard date >= "2026-10-23" else { continue }
            for metric in GarminMetric.allCases {
                if Task.isCancelled || generation != epoch { status = "同步已取消"; break outer }
                do {
                    let data = try await client.fetch(metric, date: date, now: now)
                    let object = try data.map { try JSONSerialization.jsonObject(with: $0) }
                    let payload = object.flatMap { GarminNormalizer.normalize(metric, object: $0, date: date) }
                    try await database.asyncWrite { db in
                        try GarminStore.save(db: db, metric: metric, date: date, payload: payload, attemptedAt: now)
                    }
                } catch is CancellationError { status = "同步已取消"; break outer }
                catch {
                    failures += 1; lastError = (error as? GarminAPIError)?.errorDescription ?? "Garmin 数据同步未完成"
                    let api = error as? GarminAPIError
                    var category = "transport"
                    if case .http(let code, let wait)? = api {
                        category = "http_\(code)"
                        if code == 429 { nextAllowedRefresh = now.addingTimeInterval(max(60, wait ?? 900)) }
                        else if code >= 500 { nextAllowedRefresh = now.addingTimeInterval(min(900, 60 * pow(2, Double(consecutiveFailures)))) }
                        else if code == 401 || code == 403 { nextAllowedRefresh = now.addingTimeInterval(900) }
                    } else { nextAllowedRefresh = now.addingTimeInterval(60) }
                    let errorCategory = category
                    try? await database.asyncWrite { db in
                        try GarminStore.save(db: db, metric: metric, date: date, payload: nil, attemptedAt: now, errorCategory: errorCategory)
                    }
                    consecutiveFailures = min(4, consecutiveFailures + 1)
                    // Stop the bounded run on service/auth failure; no repeated calls to every endpoint.
                    break outer
                }
            }
        }
        if failures == 0 && !Task.isCancelled { consecutiveFailures = 0; status = "同步完成；无数据项单独标记" }
        else if failures > 0 { status = "本次同步未完成，历史数据保留" }
        await load(); onDataChanged?()
    }
}
