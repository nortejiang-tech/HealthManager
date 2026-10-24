import Foundation
import GRDB

/// Resumable: each derived day is atomic and carries its own contract version.
/// Original samples and original archived report text are never modified.
enum WeightHistoryRebuilder {
    static func run(database: DatabaseManager, calendar: Calendar = .current) async throws -> Int {
        let dates: Set<String> = try await database.asyncRead { db in
            let raw = try Int64.fetchAll(db, sql: "SELECT start_at FROM health_samples_raw WHERE hk_type='HKQuantityTypeIdentifierBodyMass' AND is_deleted=0")
            let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone
            f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
            var dates = Set(raw.flatMap { timestamp -> [String] in
                let d = Date(timeIntervalSince1970: Double(timestamp))
                return [-1800.0, 0, 1800].map { f.string(from: d.addingTimeInterval($0)) }
            })
            dates.formUnion(try String.fetchAll(db, sql: "SELECT date FROM body_metrics_daily WHERE weight_kg IS NOT NULL OR sources_json IS NOT NULL"))
            let current = try String.fetchAll(db, sql: "SELECT date FROM body_metrics_daily WHERE json_valid(sources_json) AND json_extract(sources_json,'$.weightPolicyVersion')=?", arguments: [WeightAggregationPolicy.version])
            dates.subtract(current)
            return dates
        }
        var changed = 0
        for date in dates.sorted() {
            try Task.checkCancellation()
            let didChange = try await database.asyncWrite { db -> Bool in
                let p = try WeightProjection.load(db: db, date: date, calendar: calendar)
                let json = try WeightProjection.json(p)
                try db.execute(sql: """
                    INSERT INTO body_metrics_daily(date,weight_kg,sources_json,computed_at) VALUES(?,?,?,?)
                    ON CONFLICT(date) DO UPDATE SET weight_kg=excluded.weight_kg,
                      sources_json=excluded.sources_json,computed_at=excluded.computed_at
                    WHERE body_metrics_daily.weight_kg IS NOT excluded.weight_kg
                       OR body_metrics_daily.sources_json IS NOT excluded.sources_json
                    """, arguments: [date,p.mean,json,Int64(Date().timeIntervalSince1970)])
                return db.changesCount > 0
            }
            if didChange { changed += 1 }
            await Task.yield()
        }
        try await SummaryGenerator(database: database).refreshHistoricalWeightReports()
        return changed
    }
}
