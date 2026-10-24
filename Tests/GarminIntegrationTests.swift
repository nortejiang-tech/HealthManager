import XCTest
import GRDB
@testable import HealthManager

final class GarminIntegrationTests: XCTestCase {
    func testTimestampRejectsBooleanAndPreEpochDates() {
        XCTAssertNil(GarminNormalizer.timestamp(true))
        XCTAssertNil(GarminNormalizer.timestamp(false))
        XCTAssertNil(GarminNormalizer.timestamp("1960-01-01T00:00:00Z"))
        XCTAssertNil(GarminNormalizer.timestamp(Double.nan))
        XCTAssertNil(GarminNormalizer.timestamp(Double.infinity))
    }
    func testTimestampPreservesSecondsMillisecondsAndExplicitTimezone() {
        XCTAssertEqual(GarminNormalizer.timestamp(1792700000000.0), 1792700000)
        XCTAssertEqual(GarminNormalizer.timestamp("1792700000000"), 1792700000)
        XCTAssertEqual(GarminNormalizer.timestamp("2026-10-23T08:00:00+08:00"), 1792713600)
        XCTAssertEqual(GarminNormalizer.timestamp("2026-10-23T00:00:00.000"), 1792713600)
    }
    func testDailyReportIncludesVendorMetricsWithoutMixingSDNN() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        var payload = GarminMetricPayload(); payload.values["primary"] = 60
        try database.write { db in
            try GarminStore.save(db:db,metric:.hrv,date:"2026-10-23",payload:payload,attemptedAt:Date())
        }
        let report = try await SummaryGenerator(database:database).generateDaily(for:"2026-10-23")
        XCTAssertTrue(report.summaryText?.contains("Garmin 夜间 HRV：60 ms") == true)
        XCTAssertTrue(report.keyFindingsJson?.contains("garmin.hrv") == true)
    }
    func testVendorSleepUpdatesDayProjectionAndInvalidatesOnlyChangedReportData() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let generator = SummaryGenerator(database:database)
        _ = try await generator.generateDaily(for:"2026-10-23")
        var payload = GarminMetricPayload(); payload.values["sleepTimeSeconds"] = 28800; payload.values["primary"] = 85
        try database.write { db in
            try db.execute(sql:"INSERT INTO body_metrics_daily(date,weight_kg,computed_at) VALUES('2026-10-23',80,1)")
            try GarminStore.save(db:db,metric:.sleep,date:"2026-10-23",payload:payload,attemptedAt:Date())
            XCTAssertEqual(try Double.fetchOne(db,sql:"SELECT sleep_seconds FROM activity_metrics_daily WHERE date='2026-10-23'"),28800)
            XCTAssertEqual(try Double.fetchOne(db,sql:"SELECT weight_kg FROM body_metrics_daily WHERE date='2026-10-23'"),80)
            XCTAssertFalse(try String.fetchOne(db,sql:"SELECT key_findings_json FROM daily_summaries WHERE date='2026-10-23'")?.contains("sourcePolicyVersion") == true)
        }
        let updated = try await generator.currentDaily(for:"2026-10-23")
        XCTAssertTrue(updated?.summaryText?.contains("Garmin 睡眠评分：85") == true)
        let calendar = Calendar.current
        _ = try await DailyAggregator(database:database).rebuild(dates:["2026-10-23"],calendar:calendar)
        XCTAssertEqual(try database.read { try Double.fetchOne($0,sql:"SELECT sleep_seconds FROM activity_metrics_daily WHERE date='2026-10-23'") },28800)
        _ = try await generator.currentDaily(for:"2026-10-23")
        let before = try database.read { try String.fetchOne($0,sql:"SELECT key_findings_json FROM daily_summaries WHERE date='2026-10-23'") }
        try database.write { try GarminStore.save(db:$0,metric:.sleep,date:"2026-10-23",payload:payload,attemptedAt:Date()) }
        XCTAssertEqual(try database.read { try String.fetchOne($0,sql:"SELECT key_findings_json FROM daily_summaries WHERE date='2026-10-23'") },before)
    }
    func testDeviceOnlyKeychainRoundTripUsesIsolatedAccount() throws {
        let store = GarminKeyStore(account: "test-" + UUID().uuidString)
        defer { try? store.remove() }
        XCTAssertFalse(store.isConfigured)
        try store.save("fake-test-key")
        XCTAssertEqual(try store.read(), "fake-test-key")
        try store.remove()
        XCTAssertFalse(store.isConfigured)
    }
    func testIdentityMigrationPreservesBothDevicesAndRealTombstones() throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        try database.write { db in
            for (id, origin) in [("apple", "apple"), ("garmin", "garmin")] {
                try db.execute(sql: "INSERT INTO health_samples_raw(sample_uuid,hk_type,kind,value,unit,start_at,end_at,ingested_at,is_deleted,source_origin) VALUES(?,'HKQuantityTypeIdentifierHeartRate','quantity',60,'count/min',1,1,1,0,?)", arguments: [id, origin])
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_samples_raw WHERE is_deleted=0"), 2)
            try db.execute(sql: "UPDATE health_samples_raw SET is_deleted=1 WHERE sample_uuid='apple'")
        }
        try Migrations.run(on: database.pool)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM health_samples_raw WHERE is_deleted=1") }, 1)
    }
    func testStoreIsIdempotentAndFailedOrEmptyRefreshPreservesLastData() throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let date = "2026-10-23", now = Date(timeIntervalSince1970: 1000)
        var payload = GarminMetricPayload(); payload.values["primary"] = 60
        try database.write { db in
            try GarminStore.save(db: db, metric: .bodyBattery, date: date, payload: payload, attemptedAt: now)
            try GarminStore.save(db: db, metric: .bodyBattery, date: date, payload: payload, attemptedAt: now)
            try GarminStore.save(db: db, metric: .bodyBattery, date: date, payload: nil, attemptedAt: now.addingTimeInterval(60), errorCategory: "http_429")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM garmin_daily_metrics"), 1)
            let record = try XCTUnwrap(GarminStore.records(db: db, since: date).first)
            XCTAssertEqual(record.payload?.primary, 60); XCTAssertEqual(record.state, "error"); XCTAssertEqual(record.fetchedAt, now)
            try GarminStore.save(db: db, metric: .bodyBattery, date: date, payload: nil, attemptedAt: now.addingTimeInterval(120))
            XCTAssertEqual(try GarminStore.records(db: db, since: date).first?.payload?.primary, 60)
        }
    }
    func testBodyBatteryUsesDescriptorsAndRejectsPlaceholders() throws {
        let object: [[String: Any]] = [["date": "2026-10-23", "bodyBatteryValueDescriptorDTOList": [
            ["bodyBatteryValueDescriptorIndex": 0, "bodyBatteryValueDescriptorKey": "timestamp"],
            ["bodyBatteryValueDescriptorIndex": 1, "bodyBatteryValueDescriptorKey": "bodyBatteryLevel"]],
            "bodyBatteryValuesArray": [[1792700000000.0, NSNull()], [1792700001000.0, -1], [1792700002000.0, 55]]]]
        let payload = try XCTUnwrap(GarminNormalizer.normalize(.bodyBattery, object: object, date: "2026-10-23"))
        XCTAssertEqual(payload.primary, 55); XCTAssertEqual(payload.points.count, 1)
        XCTAssertEqual(payload.points.first?.timestamp, 1792700002)
    }
    func testEmptySleepIsNotARealScoreAndNeverUsesComponentAsTotal() {
        XCTAssertNil(GarminNormalizer.normalize(.sleep, object: ["deviceRemCapable": true, "retro": false], date: "2026-10-23"))
        XCTAssertNil(GarminNormalizer.normalize(.sleep, object: ["sleepScores": ["duration": ["value": 90]]], date: "2026-10-23")?.primary)
        XCTAssertEqual(GarminNormalizer.normalize(.sleep, object: ["sleepScores": ["overall": ["value": 0]]], date: "2026-10-23")?.primary, 0)
    }
    func testSleepRetainsDynamicComponentsWithoutInventingATotal() throws {
        let payload = try XCTUnwrap(GarminNormalizer.normalize(.sleep,object:["sleepScores":["vendorFutureKey":["value":82]]],date:"2026-10-23"))
        XCTAssertEqual(payload.values["score.vendorFutureKey"],82)
        XCTAssertNil(payload.primary)
    }
    func testHRVIsVendorDefinedAndStressMissingIsNotZero() {
        let hrv = GarminNormalizer.normalize(.hrv, object: ["hrvSummary": ["lastNightAvg": 55, "weeklyAvg": 50, "status": "BALANCED"]], date: "2026-10-23")
        XCTAssertEqual(hrv?.primary, 55)
        XCTAssertNil(GarminNormalizer.normalize(.stress, object: [["calendarDate": "2026-10-23", "values": ["overallStressLevel": -1]]], date: "2026-10-23"))
        XCTAssertEqual(GarminNormalizer.normalize(.stress, object: [["calendarDate": "2026-10-23", "values": ["overallStressLevel": 0]]], date: "2026-10-23")?.primary, 0)
    }
    func testBackupAndBridgeCarryOnlyNormalizedVendorData() async throws {
        let source = DatabaseManager.makeInMemoryForTesting()
        var payload = GarminMetricPayload(); payload.values["primary"] = 40
        try source.write { db in
            try BridgeSource.setEnabled(true, db: db)
            try GarminStore.save(db: db, metric: .stress, date: "2026-10-23", payload: payload, attemptedAt: Date())
            for metric in [GarminMetric.hrv, .sleep, .bodyBattery] {
                try GarminStore.save(db: db, metric: metric, date: "2026-10-23", payload: payload, attemptedAt: Date())
            }
            try GarminStore.save(db: db, metric: .hrv, date: "2026-10-23", payload: nil, attemptedAt: Date(), errorCategory: "http_403")
            try GarminStore.save(db: db, metric: .sleep, date: "2026-10-24", payload: nil, attemptedAt: Date())
            try db.execute(sql: "INSERT INTO workout_events(id,date,payload_json) VALUES('fixture-event','2026-10-23','{\"event_id\":\"fixture-event\",\"contributor_ids\":[\"garmin-fixture\",\"apple-fixture\"]}')")
            try BridgeSource.prepare(db, historyStart: Date(timeIntervalSince1970: 0))
        }
        let bridge = try source.read { try Data.fetchOne($0, sql: "SELECT payload FROM bridge_outbox ORDER BY sequence DESC LIMIT 1")! }
        XCTAssertTrue(String(decoding: bridge, as: UTF8.self).contains("garmin_daily_metrics"))
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: package) }
        let manifest = try await BackupExporter(database: source).export(to: package)
        XCTAssertEqual(manifest.formatVersion, BackupManifest.currentFormatVersion)
        let target = DatabaseManager.makeInMemoryForTesting()
        _ = try await BackupImporter(database: target).importPackage(from: package)
        XCTAssertEqual(try target.read { try GarminStore.records(db: $0, since: "2026-10-23").first { $0.metric == .stress }?.payload?.primary }, 40)
        let restored = try target.read { try GarminStore.records(db: $0, since: "2026-10-23") }
        XCTAssertEqual(restored.count, 5)
        XCTAssertEqual(restored.first { $0.metric == .hrv }?.state, "error")
        XCTAssertEqual(restored.first { $0.metric == .hrv }?.payload?.primary, 40)
        XCTAssertNil(restored.first { $0.metric == .sleep && $0.date == "2026-10-24" }?.payload)
        XCTAssertEqual(try source.read { try String.fetchOne($0, sql: "SELECT payload_json FROM workout_events") },
                       try target.read { try String.fetchOne($0, sql: "SELECT payload_json FROM workout_events") })
        _ = try await BackupImporter(database: target).importPackage(from: package)
        XCTAssertEqual(try target.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM garmin_daily_metrics") }, 5)
    }
}

private struct TestGarminCredentials: GarminCredentialSource {
    func read() throws -> String { "fake-test-key" }
}
private actor TestGarminTransport: GarminHTTPTransport {
    struct Reply { let status: Int; let data: Data; var headers: [String: String] = [:] }
    var replies: [Reply]
    var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw GarminAPIError.transport }
        let reply = replies.removeFirst()
        return (reply.data, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!)
    }
}
final class GarminClientTests: XCTestCase {
    private func jwt(expiry: Int = 4102444800) -> Data {
        let body = Data("{\"exp\":\(expiry)}".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return Data("eyJhbGciOiJub25lIn0.\(body).fake".utf8)
    }
    func testPlainTextTokenAndChinaOnlyRequests() async throws {
        let transport = TestGarminTransport([.init(status: 200, data: jwt()), .init(status: 204, data: Data())])
        let client = GarminClient(credentials: TestGarminCredentials(), transport: transport)
        let result = try await client.fetch(.hrv, date: "2026-10-23")
        XCTAssertNil(result)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Accept"), "*/*")
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == GarminClient.host })
    }
    func test401ReauthenticatesExactlyOnce() async throws {
        let transport = TestGarminTransport([.init(status: 200, data: jwt()), .init(status: 401, data: Data()), .init(status: 200, data: jwt()), .init(status: 401, data: Data())])
        let client = GarminClient(credentials: TestGarminCredentials(), transport: transport)
        do { _ = try await client.fetch(.sleep, date: "2026-10-23"); XCTFail("Expected auth failure") }
        catch { XCTAssertEqual(error as? GarminAPIError, .http(401, retryAfter: nil)) }
        let count = await transport.requests.count; XCTAssertEqual(count, 4)
    }
    func testRedirectAndRateLimitDoNotFallbackOrRetry() async throws {
        for code in [302, 429] {
            let transport = TestGarminTransport([.init(status: code, data: Data(), headers: ["Retry-After": "120"])])
            let client = GarminClient(credentials: TestGarminCredentials(), transport: transport)
            do { _ = try await client.fetch(.stress, date: "2026-10-23"); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? GarminAPIError, code == 302 ? .redirectRejected : .http(429, retryAfter: 120)) }
            let count = await transport.requests.count; XCTAssertEqual(count, 1)
        }
    }

    func testExpiredTokenIsRejectedBeforeAnyMetricRequest() async throws {
        let transport = TestGarminTransport([.init(status: 200, data: jwt(expiry: 1))])
        let client = GarminClient(credentials: TestGarminCredentials(), transport: transport)
        do { _ = try await client.fetch(.hrv, date: "2026-10-23"); XCTFail("Expected expiry rejection") }
        catch { XCTAssertEqual(error as? GarminAPIError, .invalidToken) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testForbiddenDoesNotReauthenticateOrTryOtherRegion() async throws {
        let transport = TestGarminTransport([.init(status: 200, data: jwt()), .init(status: 403, data: Data())])
        let client = GarminClient(credentials: TestGarminCredentials(), transport: transport)
        do { _ = try await client.fetch(.hrv, date: "2026-10-23"); XCTFail("Expected permission rejection") }
        catch { XCTAssertEqual(error as? GarminAPIError, .http(403, retryAfter: nil)) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == GarminClient.host })
    }

    func testNetworkFailureStopsWithoutRetryLoop() async throws {
        let transport = TestGarminTransport([.init(status: 200, data: jwt())])
        let client = GarminClient(credentials: TestGarminCredentials(), transport: transport)
        do { _ = try await client.fetch(.hrv, date: "2026-10-23"); XCTFail("Expected interrupted request") }
        catch { XCTAssertEqual(error as? GarminAPIError, .transport) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 2)
    }
}
