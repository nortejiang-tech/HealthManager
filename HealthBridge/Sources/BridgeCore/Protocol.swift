import Foundation
import CryptoKit
import GRDB

public enum BridgeError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let s) = self { return s }; return "Bridge error" }
}
public struct BridgeRecord: Codable, Sendable {
    public let table: String
    public let key: String
    public let json: String? // nil is an explicit tombstone
    public init(table: String, key: String, json: String?) { self.table = table; self.key = key; self.json = json }
}
public struct BridgeManifest: Codable, Sendable {
    public var version = 1
    public let dataset: String
    public let epoch: String
    public let epochStarted: Double
    public let sequence: Int64
    public let snapshot: Bool
    public let finalSnapshot: Bool
    public let historyStart: Double
    public let timeZone: String
    public let generatedAt: Double
    public let count: Int
    public let bytes: Int
    public let sha256: String
}
public struct BridgeReceipt: Codable, Sendable {
    public let dataset: String
    public let epoch: String
    public let sequence: Int64
    public let sha256: String
    public let receivedAt: Double
}
public enum BridgeWire {
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    public static func validID(_ value: String) -> Bool { UUID(uuidString: value) != nil }
    public static func folder(_ m: BridgeManifest) -> String { "\(m.epoch)-\(String(format: "%012lld", m.sequence))" }
    public static let types = ["HKCategoryTypeIdentifierSleepAnalysis", "HKQuantityTypeIdentifierStepCount", "HKQuantityTypeIdentifierActiveEnergyBurned", "HKQuantityTypeIdentifierAppleExerciseTime", "HKQuantityTypeIdentifierHeartRate", "HKQuantityTypeIdentifierRestingHeartRate", "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", "HKQuantityTypeIdentifierBodyMass", "HKWorkoutTypeIdentifier"]
    public static let tables: [(name: String, key: String)] = [
        ("health_samples_raw", "sample_uuid"), ("meal_records", "id"), ("meal_items", "id"),
        ("medication_plans", "id"), ("medication_logs", "id"),
        ("activity_metrics_daily", "date"), ("body_metrics_daily", "date"), ("data_quality_daily", "date")
    ]
    public static func object(_ row: Row) -> [String: Any] {
        var result: [String: Any] = [:]
        for (name, value) in row {
            guard name != "photo_path" else { continue }
            switch value.storage {
            case .null: result[name] = NSNull()
            case .int64(let v): result[name] = v
            case .double(let v): result[name] = v.isFinite ? v as Any : NSNull()
            case .string(let v): result[name] = v
            case .blob: break
            }
        }
        // Only structured sample fields required for queries; arbitrary HK metadata is excluded.
        if let raw = result["extra_json"] as? String, let data = raw.data(using: .utf8),
           let extra = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let allowed = ["categoryValue", "sleepStage", "activityType", "duration", "totalEnergyKcal", "totalDistanceMeters"]
            let safe = extra.filter { allowed.contains($0.key) }
            result["extra_json"] = String(data: (try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys])) ?? Data("{}".utf8), encoding: .utf8)
        }
        return result
    }
    public static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    public static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let e = coordinationError { throw e }; if let e = writeError { throw e }
    }
    public static func coordinatedRead(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw BridgeError.invalid("Symbolic links are not accepted") }
        if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw BridgeError.invalid("等待 iCloud 下载完整文件")
        }
        var coordinationError: NSError?; var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result { try Data(contentsOf: target) }
        }
        if let e = coordinationError { throw e }
        guard let result else { throw BridgeError.invalid("File coordination incomplete") }
        return try result.get()
    }
}
