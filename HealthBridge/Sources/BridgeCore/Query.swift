import Foundation
import GRDB

public final class BridgeQuery {
    let store: BridgeStore
    public static let tools = BridgeToolCatalog.descriptors.map(\.name)
    public init(store: BridgeStore) { self.store = store }
    /// All tool paths share one SQLite read snapshot and cannot issue arbitrary SQL.
    public func call(_ tool: String, arguments a: [String: Any] = [:]) throws -> String {
        guard let descriptor = BridgeToolCatalog.descriptors.first(where: { $0.name == tool }) else { throw BridgeError.invalid("Unknown tool") }
        guard Set(a.keys).isSubset(of:Set(descriptor.arguments)), descriptor.required.allSatisfy({ a[$0] != nil }) else {
            throw BridgeError.invalid("Missing required or unsupported arguments: " + descriptor.required.joined(separator:","))
        }
        return try store.pool.read { db in
            let state = try Row.fetchOne(db, sql: "SELECT * FROM receiver_state WHERE id=1")!
            let active: String? = state["active_epoch"]
            let epoch = try active.flatMap { try Row.fetchOne(db, sql: "SELECT * FROM epochs WHERE epoch=?", arguments: [$0]) }
            var meta = BridgeWire.object(state)
            if let epoch { meta.merge(BridgeWire.object(epoch)) { _, b in b } }
            meta["status"] = active == nil ? "pending_initial_snapshot" : "available"
            meta["replica_boundary"] = "HealthManager normalized records, not a lossless Apple Health mirror"
            meta["read_authorization"] = "not_observable"
            if let epoch {
                let generated: Double = epoch["generated_at"]
                meta["exportAgeSeconds"] = max(0, Date().timeIntervalSince1970-generated)
                meta["freshness"] = Date().timeIntervalSince1970-generated > 86400 ? "stale_export" : "recent_export_not_proof_of_current_sensor_data"
                if let active {
                    let coverage = try Row.fetchAll(db, sql: "SELECT json_extract(json, '$.hk_type') AS type, COUNT(*) AS sampleCount, MIN(json_extract(json, '$.start_at')) AS earliestSampleAt, MAX(json_extract(json, '$.end_at')) AS latestSampleAt FROM replica WHERE epoch=? AND entity='health_samples_raw' GROUP BY type", arguments: [active])
                    meta["observedCoverage"] = coverage.map(BridgeWire.object)
                }
            }
            if tool == "health_sync_status" { return try BridgeWire.json(meta) }
            guard let active, let epoch else { throw BridgeError.invalid("尚无完整快照，请先完成手机同步") }
            let zone: String = epoch["timezone"]
            let context = try QueryContext(a: a, zone: zone)
            let result = try execute(tool, db: db, epoch: active, context: context, a: a)
            return try BridgeWire.json(["meta":meta,"query":a,"timeZone":zone,"result":result])
        }
    }
    private func rows(_ db: Database, epoch: String, entity: String) throws -> [[String: Any]] {
        try String.fetchAll(db, sql: "SELECT json FROM replica WHERE epoch=? AND entity=? ORDER BY record_key", arguments: [epoch,entity]).map {
            guard let d = $0.data(using: .utf8), let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw BridgeError.invalid("Corrupt replica JSON") }; return o
        }
    }
    private func filtered(_ records: [[String: Any]], entity: String, c: QueryContext, a: [String: Any]) -> [[String: Any]] {
        records.filter { r in
            if let source = a["source"] as? String, r["source_bundle_id"] as? String != source { return false }
            if let type = a["type"] as? String, r["hk_type"] as? String != type { return false }
            if let day = r["date"] as? String { return day >= c.fromDay && day <= c.toDay }
            let field: String
            switch entity {
            case "meal_records": field = "eaten_at"
            case "medication_logs": field = "scheduled_at"
            case "medication_plans": return true // schedule is not evidence of taking a dose
            default: field = "start_at"
            }
            guard let start = (r[field] as? NSNumber)?.doubleValue else { return false }
            let end = (r["end_at"] as? NSNumber)?.doubleValue ?? start
            return start < c.end && end >= c.start
        }
    }
    private func page(_ records: [[String: Any]], a: [String: Any]) throws -> [String: Any] {
        let offset = (a["offset"] as? Int) ?? 0; let limit = (a["limit"] as? Int) ?? 100
        guard offset >= 0 && offset <= Int.max - 1000 && limit > 0 && limit <= 1000 else { throw BridgeError.invalid("offset >= 0; limit 1...1000") }
        let next = min(records.count,offset+limit)
        return ["records":Array(records.dropFirst(offset).prefix(limit)),"total":records.count,"nextOffset":next < records.count ? next as Any : NSNull()]
    }
    private func execute(_ tool: String, db: Database, epoch: String, context c: QueryContext, a: [String: Any]) throws -> Any {
        switch tool {
        case "health_records":
            let entity = a["category"] as? String ?? "health_samples_raw"
            guard BridgeWire.tables.contains(where: { $0.name == entity }) else { throw BridgeError.invalid("Unknown category") }
            if entity == "health_samples_raw" { return try rawPage(db, epoch: epoch, c: c, a: a) }
            var all = try rows(db, epoch: epoch, entity: entity)
            if entity == "meal_items" {
                let meals = filtered(try rows(db, epoch: epoch, entity: "meal_records"),entity:"meal_records",c:c,a:a)
                let ids = Set(meals.compactMap { ($0["id"] as? NSNumber)?.int64Value })
                all = all.filter { ids.contains(($0["meal_id"] as? NSNumber)?.int64Value ?? -1) }
            } else { all = filtered(all,entity:entity,c:c,a:a) }
            return try page(all,a:a)
        case "health_workouts":
            var filter = a; filter["type"] = "HKWorkoutTypeIdentifier"
            return try rawPage(db, epoch: epoch, c: c, a: filter)
        case "health_meals":
            let meals = filtered(try rows(db,epoch:epoch,entity:"meal_records"),entity:"meal_records",c:c,a:a)
            let items = try rows(db,epoch:epoch,entity:"meal_items")
            return try page(meals.map { meal in
                var m = meal; m["items"] = items.filter { ($0["meal_id"] as? NSNumber) == (meal["id"] as? NSNumber) }; return m
            },a:a)
        case "health_medications":
            return ["plans":try page(rows(db,epoch:epoch,entity:"medication_plans"),a:a),
                    "logs":try page(filtered(rows(db,epoch:epoch,entity:"medication_logs"),entity:"medication_logs",c:c,a:a),a:a),
                    "meaning":"plans are not evidence of administration; use log action/action_at"] as [String: Any]
        case "health_sleep": return try sleep(db,epoch:epoch,c:c)
        case "health_metric_history": return try history(db,epoch:epoch,c:c,metric:a["metric"] as? String ?? "weight")
        case "health_compare":
            guard let fa = a["fromA"] as? String, let ta = a["toA"] as? String, let fb = a["fromB"] as? String, let tb = a["toB"] as? String else { throw BridgeError.invalid("Require fromA,toA,fromB,toB") }
            let ca = try QueryContext(a:["from":fa,"to":ta],zone:c.zone), cb = try QueryContext(a:["from":fb,"to":tb],zone:c.zone)
            let metric = a["metric"] as? String ?? "weight"
            let ha = try history(db,epoch:epoch,c:ca,metric:metric), hb = try history(db,epoch:epoch,c:cb,metric:metric)
            let sa = stats((ha["values"] as? [[String:Any]] ?? []).compactMap { ($0["value"] as? NSNumber)?.doubleValue })
            let sb = stats((hb["values"] as? [[String:Any]] ?? []).compactMap { ($0["value"] as? NSNumber)?.doubleValue })
            let ma = sa["mean"] as? Double, mb = sb["mean"] as? Double
            return ["periodA":ha,"periodB":hb,"statisticsA":sa,"statisticsB":sb,"difference": ma != nil && mb != nil ? ma! - mb! as Any : NSNull(),"interpretation":"descriptive only; missing days excluded; no causal inference"] as [String:Any]
        case "health_daily_summary":
            let mealResult = try execute("health_meals",db:db,epoch:epoch,context:c,a:a)
            let dayMeals = filtered(try rows(db,epoch:epoch,entity:"meal_records"),entity:"meal_records",c:c,a:a)
            let activity = filtered(try rows(db,epoch:epoch,entity:"activity_metrics_daily"),entity:"activity_metrics_daily",c:c,a:a)
            let nutrition = Self.nutritionSummary(dayMeals)
            return ["activity":activity,
                    "body":filtered(try rows(db,epoch:epoch,entity:"body_metrics_daily"),entity:"body_metrics_daily",c:c,a:a),
                    "quality":filtered(try rows(db,epoch:epoch,entity:"data_quality_daily"),entity:"data_quality_daily",c:c,a:a),
                    "meals":mealResult,"medications":try execute("health_medications",db:db,epoch:epoch,context:c,a:a),
                    "nutrition":nutrition,
                    "energyBalance":Self.energyBalance(active:activity.first.flatMap { Self.validValue($0["active_energy_kcal"]) },
                                                     basal:activity.first.flatMap { Self.validValue($0["basal_energy_kcal"]) },
                                                     intake:nutrition["calorieIntakeKcal"] as? Double, hasMeals:!dayMeals.isEmpty,
                                                     invalidActiveEnergy:activity.first.map { Self.invalidEnergyValue($0["active_energy_kcal"]) } ?? false,
                                                     invalidBasalEnergy:activity.first.map { Self.invalidEnergyValue($0["basal_energy_kcal"]) } ?? false)] as [String:Any]
        default: throw BridgeError.invalid("Unsupported query")
        }
    }
    private func rawPage(_ db: Database, epoch: String, c: QueryContext, a: [String:Any]) throws -> [String:Any] {
        let offset = a["offset"] as? Int ?? 0; let limit = a["limit"] as? Int ?? 100
        guard offset >= 0, offset <= Int.max - 1000, limit > 0, limit <= 1000 else { throw BridgeError.invalid("Invalid pagination") }
        var whereSQL = "epoch=? AND entity='health_samples_raw' AND json_extract(json,'$.start_at')<? AND json_extract(json,'$.end_at')>=?"
        var args: StatementArguments = [epoch,c.end,c.start]
        if let type = a["type"] as? String { whereSQL += " AND json_extract(json,'$.hk_type')=?"; args += [type] }
        if let source = a["source"] as? String { whereSQL += " AND json_extract(json,'$.source_bundle_id')=?"; args += [source] }
        let total = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM replica WHERE " + whereSQL,arguments:args) ?? 0
        args += [limit,offset]
        let strings = try String.fetchAll(db,sql:"SELECT json FROM replica WHERE " + whereSQL + " ORDER BY json_extract(json,'$.start_at'),record_key LIMIT ? OFFSET ?",arguments:args)
        let records = try strings.map { try JSONSerialization.jsonObject(with:Data($0.utf8)) }
        return ["records":records,"total":total,"nextOffset":offset+limit < total ? offset+limit as Any : NSNull()]
    }
    private func stats(_ v: [Double]) -> [String: Any] {
        let sorted = v.sorted(); guard !v.isEmpty else { return ["count":0,"mean":NSNull(),"median":NSNull()] }
        let median = sorted.count % 2 == 0 ? (sorted[sorted.count/2-1]+sorted[sorted.count/2])/2 : sorted[sorted.count/2]
        return ["count":v.count,"mean":v.reduce(0,+)/Double(v.count),"median":median]
    }
    private func history(_ db: Database, epoch: String, c: QueryContext, metric: String) throws -> [String:Any] {
        if metric == "calorie_intake" || metric == "calorie_deficit" {
            let meals = try rows(db,epoch:epoch,entity:"meal_records")
            let activity = try rows(db,epoch:epoch,entity:"activity_metrics_daily")
            var mealsByDay: [String:[[String:Any]]] = [:]
            for meal in meals { if let day = Self.day(for: (meal["eaten_at"] as? NSNumber)?.doubleValue, zone: c.zone) { mealsByDay[day, default: []].append(meal) } }
            var activityByDay: [String:[String:Any]] = [:]
            for row in activity { if let day = row["date"] as? String { activityByDay[day] = row } }
            var values: [[String:Any]] = []; var day = c.startDate
            while day.timeIntervalSince1970 < c.end {
                let key = c.formatter.string(from: day)
                let nutrition = Self.nutritionSummary(mealsByDay[key] ?? [])
                let row = activityByDay[key]
                let value: Any = metric == "calorie_intake"
                    ? (nutrition["calorieIntakeKcal"] as Any? ?? NSNull())
                    : (Self.energyBalance(active: row.flatMap { Self.validValue($0["active_energy_kcal"]) },
                                        basal: row.flatMap { Self.validValue($0["basal_energy_kcal"]) },
                                        intake: nutrition["calorieIntakeKcal"] as? Double, hasMeals: !(mealsByDay[key] ?? []).isEmpty,
                                        invalidActiveEnergy: row.map { Self.invalidEnergyValue($0["active_energy_kcal"]) } ?? false,
                                        invalidBasalEnergy: row.map { Self.invalidEnergyValue($0["basal_energy_kcal"]) } ?? false)["calorieDeficitKcal"] as Any? ?? NSNull())
                values.append(["date":key,"value":value is NSNull ? NSNull() : value,"sources":row?["sources_json"] ?? NSNull(),"sampleCount":nutrition["mealCount"] as Any])
                day = c.calendar.date(byAdding:.day,value:1,to:day)!
            }
            let valid = values.filter { $0["value"] is NSNumber }.count
            return ["metric":metric,"unit":"kcal","method":metric == "calorie_intake" ? "sum of persisted meal_records calorie snapshot for each local calendar day; missing, negative or non-finite meal calories make that day unknown; never zero-filled; meal_items are not used" : "basal_energy_kcal + active_energy_kcal - calorie_intake_kcal per local calendar day; missing, negative or non-finite required input makes that day unknown; never zero-filled","values":values,"validDays":valid,"missingDays":values.count-valid]
        }
        let map: [String:(String,String,String)] = ["weight":("body_metrics_daily","weight_kg","kg"),"steps":("activity_metrics_daily","step_count","count"),"active_energy":("activity_metrics_daily","active_energy_kcal","kcal"),"exercise_minutes":("activity_metrics_daily","exercise_minutes","min"),"heart_rate":("activity_metrics_daily","avg_hr_bpm","bpm"),"resting_heart_rate":("activity_metrics_daily","resting_hr_bpm","bpm"),"hrv_daily_mean":("activity_metrics_daily","hrv_ms","ms"),"sleep_duration":("activity_metrics_daily","sleep_seconds","s")]
        guard let spec = map[metric] else { throw BridgeError.invalid("Unknown metric; use weight,steps,active_energy,exercise_minutes,heart_rate,resting_heart_rate,hrv_daily_mean,sleep_duration,calorie_intake,calorie_deficit") }
        let all = try rows(db,epoch:epoch,entity:spec.0)
        var byDay: [String:[String:Any]] = [:]
        for row in all { if let day = row["date"] as? String { byDay[day] = row } }
        var values: [[String:Any]] = []; var day = c.startDate
        while day.timeIntervalSince1970 < c.end {
            let key = c.formatter.string(from: day); let r = byDay[key]
            values.append(["date":key,"value":r?[spec.1] ?? NSNull(),"sources":r?["sources_json"] ?? NSNull(),"sampleCount":NSNull()])
            day = c.calendar.date(byAdding:.day,value:1,to:day)!
        }
        let valid = values.filter { $0["value"] is NSNumber }.count
        return ["metric":metric,"unit":spec.2,"method":"HealthManager daily projection; source policy preserved; no cross-device summation; sample count unavailable in projection","values":values,"validDays":valid,"missingDays":values.count-valid]
    }
    /// Accept only a finite, non-negative numeric value. Missing, non-numeric,
    /// negative, NaN and infinity all stay unknown (nil) and are never zero-filled.
    private static func validValue(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite && value >= 0 ? value : nil
    }
    private static func invalidEnergyValue(_ raw: Any?) -> Bool {
        guard let raw, !(raw is NSNull) else { return false }
        return validValue(raw) == nil
    }
    private static func day(for timestamp: Double?, zone: String) -> String? {
        guard let timestamp, timestamp.isFinite else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: zone); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
    /// Deterministic nutrition totals from the persisted meal_records snapshot for
    /// one queried local calendar day. A metric is unknown (NSNull) when any meal
    /// for that day lacks it, is negative or is non-finite.
    private static func nutritionSummary(_ meals: [[String: Any]]) -> [String: Any] {
        guard !meals.isEmpty else {
            return ["mealCount":0,
                    "calorieIntakeKcal":NSNull(),"proteinG":NSNull(),"fatG":NSNull(),"carbsG":NSNull(),
                    "calorieStatus":"no_meals",
                    "method":"sum of persisted meal_records snapshot fields (calories_kcal, protein_g, fat_g, carbs_g) for meals whose eaten_at falls on the queried local calendar day; every contributing value must be finite and non-negative, otherwise the total is null; meal_items are not used and missing values are never treated as zero"] as [String: Any]
        }
        func total(_ field: String) -> Any {
            var sum = 0.0
            for meal in meals {
                guard let value = validValue(meal[field]) else { return NSNull() }
                sum += value
                guard sum.isFinite else { return NSNull() }
            }
            return sum
        }
        let calories = total("calories_kcal")
        let status: String
        if calories is NSNull { status = "incomplete" }
        else { status = "complete" }
        return ["mealCount": meals.count,
                "calorieIntakeKcal": calories,
                "proteinG": total("protein_g"),
                "fatG": total("fat_g"),
                "carbsG": total("carbs_g"),
                "calorieStatus": status,
                "method": "sum of persisted meal_records snapshot fields (calories_kcal, protein_g, fat_g, carbs_g) for meals whose eaten_at falls on the queried local calendar day; every contributing value must be finite and non-negative, otherwise the total is null; meal_items are not used and missing values are never treated as zero"] as [String: Any]
    }
    /// energyBalance = basal_energy_kcal + active_energy_kcal - calorie_intake_kcal.
    /// Missing or invalid input is reported as unknown, never as zero.
    private static func energyBalance(active: Double?, basal: Double?, intake: Double?, hasMeals: Bool, invalidActiveEnergy: Bool, invalidBasalEnergy: Bool) -> [String: Any] {
        let total = active.flatMap { active in basal.flatMap { basal in
            let value = active + basal
            return value.isFinite ? value : nil
        } }
        let deficit = total.flatMap { total in intake.flatMap { intake in
            let value = total - intake
            return value.isFinite ? value : nil
        } }
        let status: String
        if active == nil { status = invalidActiveEnergy ? "invalid_energy_inputs" : "missing_active_energy" }
        else if basal == nil { status = invalidBasalEnergy ? "invalid_energy_inputs" : "missing_basal_energy" }
        else if total == nil { status = "invalid_energy_inputs" }
        else if intake == nil { status = hasMeals ? "incomplete_calorie_intake" : "no_meals" }
        else { status = "complete" }
        return ["activeEnergyKcal": active as Any? ?? NSNull(),
                "basalEnergyKcal": basal as Any? ?? NSNull(),
                "totalEnergyExpenditureKcal": total as Any? ?? NSNull(),
                "calorieIntakeKcal": intake as Any? ?? NSNull(),
                "calorieDeficitKcal": deficit as Any? ?? NSNull(),
                "status": status,
                "method": "calorieDeficitKcal = basal_energy_kcal + active_energy_kcal - calorie_intake_kcal; totalEnergyExpenditureKcal = basal_energy_kcal + active_energy_kcal; all inputs must be finite and non-negative (calorieDeficitKcal may be negative); missing input yields null and is never substituted with zero"] as [String: Any]
    }
    private func sleep(_ db: Database, epoch: String, c: QueryContext) throws -> [String: Any] {
        guard c.fromDay == c.toDay else { throw BridgeError.invalid("health_sleep takes one wake date") }
        // 18:00 previous day through 18:00 wake day; clipped segments, never double count overlap.
        let window = try BridgeCalendarWindow.sleep(wakeDate:c.fromDay,timeZone:c.zone)
        let begin = window.start.timeIntervalSince1970
        let end = window.end.timeIntervalSince1970
        let rawJSON = try String.fetchAll(db, sql: "SELECT json FROM replica WHERE epoch=? AND entity='health_samples_raw' AND json_extract(json,'$.start_at')<? AND json_extract(json,'$.end_at')>? AND json_extract(json,'$.hk_type') IN ('HKCategoryTypeIdentifierSleepAnalysis','HKQuantityTypeIdentifierHeartRateVariabilitySDNN')", arguments: [epoch,end,begin])
        let raw = try rawJSON.map { try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any] }
        let samples = raw.filter { ($0["hk_type"] as? String) == "HKCategoryTypeIdentifierSleepAnalysis" && (($0["start_at"] as? Double) ?? 0) < end && (($0["end_at"] as? Double) ?? 0) > begin }
        let groups = Dictionary(grouping:samples) { $0["source_bundle_id"] as? String ?? "unknown" }
        func priority(_ source: String, _ rows: [[String:Any]]) -> Int {
            let origin = rows.first?["source_origin"] as? String ?? "unknown"
            return ["garmin":100,"apple":50,"xiaomiMijia":30,"xiaomiSports":30,"hutool":20,"manual":10,"unknown":0][origin] ?? 10
        }
        let selected = groups.keys.sorted { a,b in let pa = priority(a,groups[a]!), pb = priority(b,groups[b]!); if pa != pb { return pa > pb }; let da = groups[a]!.reduce(0.0) { $0 + max(0,(($1["end_at"] as? Double) ?? 0)-(($1["start_at"] as? Double) ?? 0)) }; let db = groups[b]!.reduce(0.0) { $0 + max(0,(($1["end_at"] as? Double) ?? 0)-(($1["start_at"] as? Double) ?? 0)) }; return da == db ? a < b : da > db }.first
        guard let selected else { return ["wakeDate":c.fromDay,"totalSleepSeconds":NSNull(),"stages":NSNull(),"status":"no_observed_data"] }
        let records = groups[selected]!
        let points = Set(records.flatMap { r in [max(begin,(r["start_at"] as? Double) ?? begin),min(end,(r["end_at"] as? Double) ?? end)] }).sorted()
        var stages: [String:Double] = [:]; var total = 0.0; var conflicts = 0; var asleepIntervals: [(Double,Double)] = []
        let labels = [0:"inBed",1:"unspecified",2:"awake",3:"core",4:"deep",5:"rem"]
        for (s,e) in zip(points,points.dropFirst()) where e > s {
            let covered = records.filter { (($0["start_at"] as? Double) ?? 0) < e && (($0["end_at"] as? Double) ?? 0) > s }
            let codes = Set(covered.compactMap { ($0["value"] as? NSNumber)?.intValue }).subtracting([0])
            guard !codes.isEmpty else { continue }
            let detailed = codes.subtracting([1])
            let effective = detailed.isEmpty ? codes : detailed
            let conflict = effective.count > 1
            if conflict { conflicts += 1 }
            let code = effective.first!
            let label = conflict ? "conflict" : labels[code] ?? "unknown"
            stages[label,default:0] += e-s
            // Awake/asleep disagreement is not confidently asleep.
            if effective.isSubset(of:[1,3,4,5]) { total += e-s; asleepIntervals.append((s,e)) }
        }
        let hrv = raw.filter { r in
            guard r["hk_type"] as? String == "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", let start = r["start_at"] as? Double else { return false }
            return asleepIntervals.contains { start >= $0.0 && start < $0.1 }
        }.compactMap { $0["value"] as? Double }
        return ["wakeDate":c.fromDay,"window":"previous 18:00 to wake-date 18:00, local time; naps outside window excluded","source":selected,"otherSources":groups.keys.filter{$0 != selected}.sorted(),"totalSleepSeconds":asleepIntervals.isEmpty ? NSNull() as Any : total,"stages":stages,"stageStatus":conflicts > 0 ? "conflicting" : (stages["unspecified"] != nil ? "incomplete" : "observed"),"conflictIntervals":conflicts,"nightHRV":stats(hrv),"nightHRVUnit":"ms","nightHRVMethod":"samples overlapping non-conflicting asleep intervals; median distinct from daily mean"]
    }
}
private struct QueryContext {
    let zone: String; let calendar: Calendar; let formatter: DateFormatter
    let fromDay: String; let toDay: String; let start: Double; let end: Double; let startDate: Date
    init(a: [String:Any], zone: String) throws {
        self.zone = zone
        var cal = Calendar(identifier:.gregorian); cal.timeZone = TimeZone(identifier:zone)!
        let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        let from = a["from"] as? String ?? a["date"] as? String ?? f.string(from:Date())
        let to = a["to"] as? String ?? from
        guard let s = f.date(from:from), let e = f.date(from:to), f.string(from:s)==from, f.string(from:e)==to, e>=s,
              let days = cal.dateComponents([.day],from:s,to:e).day, days <= 3660 else { throw BridgeError.invalid("Use valid yyyy-MM-dd dates; maximum range 3661 days") }
        self.calendar=cal;self.formatter=f;self.fromDay=from;self.toDay=to;self.startDate=s;self.start=s.timeIntervalSince1970;self.end=cal.date(byAdding:.day,value:1,to:e)!.timeIntervalSince1970
    }
}
