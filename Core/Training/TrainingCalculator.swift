import Foundation

enum TrainingCalculator {
    static let historyDays = 56
    // Display + personal-reference days + load baseline + resting baseline + sleep buffer.
    static let inputHistoryDays = 56 + 28 + 28 + 28 + 2
    static let maximumHeartGap: TimeInterval = 30

    static func snapshot(samples input: [TrainingSample], health: [TrainingHealthMetric] = [],
                         now: Date, calendar: Calendar) -> TrainingSnapshot {
        let today = calendar.startOfDay(for: now)
        let begin = calendar.date(byAdding: .day, value: -(historyDays - 1), to: today)!
        let inputBegin = calendar.date(byAdding: .day, value: -inputHistoryDays, to: today)!
        let samples = input.filter {
            $0.value.isFinite && $0.start <= now && $0.end <= now && $0.ingestedAt <= now && $0.end >= $0.start
                && $0.start >= inputBegin
        }
        let hearts = samples.filter { $0.type == TrainingTypes.heart && (25...230).contains($0.value) }
        let heartsBySource = Dictionary(grouping: hearts, by: \.source).mapValues {
            $0.sorted { $0.start < $1.start }
        }
        let hrv = samples.filter { $0.type == TrainingTypes.hrv && $0.value > 0 && $0.value <= 500 }
        let nights = sleepNights(samples: samples, hearts: hearts, hrv: hrv, now: now, calendar: calendar)
        let workoutInputs = samples.filter {
            $0.type == TrainingTypes.workout && $0.end > $0.start
                && ($0.duration ?? 0) > 0 && ($0.duration ?? 0).isFinite
        }
        let workouts = deduplicatedWorkouts(workoutInputs)
        let allSessions = workouts.map { workout in
            session(workout, hearts: heartsBySource[workout.source] ?? [], resting: samples.filter { $0.type == TrainingTypes.resting },
                    nights: nights, workouts: workouts, calendar: calendar)
        }.sorted { $0.start > $1.start }
        let sessions = allSessions.filter { $0.start >= begin }
        let history = readinessHistory(nights: nights, workouts: workoutInputs, hearts: heartsBySource,
            resting: samples.filter { $0.type == TrainingTypes.resting }, now: now, calendar: calendar)
        var current = history.last(where: { $0.assessment.observedAt != nil })?.assessment
            ?? readiness(nights: [], sessions: [], now: now)
        if let observed = current.observedAt, now.timeIntervalSince(observed) > 30 * 3600 {
            current = TrainingReadiness(score: nil, credibility: "本次未评估", baselineNights: current.baselineNights,
                factors: current.factors, missingReasons: ["主睡眠记录已超过30小时"], observedAt: observed,
                source: current.source)
        }
        let keyedNights = Dictionary(nights.map { ($0.dayKey, $0) }, uniquingKeysWith: { _, b in b })
        let days = (0..<historyDays).map { offset -> TrainingDay in
            let date = calendar.date(byAdding: .day, value: offset, to: begin)!
            let next = calendar.date(byAdding: .day, value: 1, to: date)!
            let entries = sessions.filter { $0.start >= date && $0.start < next }
            let runs = entries.filter(\.isRun)
            var day = TrainingDay(key: dayKey(date, calendar), date: date)
            day.runKm = runs.compactMap(\.distanceKm).reduce(0, +)
            day.runMinutes = runs.map(\.minutes).reduce(0, +)
            day.sessionCount = entries.count
            day.missingLoadCount = entries.filter { $0.load == nil }.count
            day.missingDistanceCount = runs.filter { $0.distanceKm == nil }.count
            // No recorded workout is not proof of a physiological rest day.
            let loads = entries.compactMap(\.load)
            day.recordedLoad = loads.isEmpty ? nil : loads.reduce(0, +)
            day.night = keyedNights[day.key]
            return day
        }
        return TrainingSnapshot(
            calculatedAt: now,
            latestMeasurementAt: samples.map(\.end).max(),
            latestIngestionAt: samples.map(\.ingestedAt).max(), sessions: sessions, days: days,
            readiness: current,
            health: health.filter { $0.value.isFinite && $0.measuredOn <= now },
            comparison: comparison(sessions), intraday: intraday(hearts: hearts, workouts: workouts, now: now),
            readinessHistory: Array(history.suffix(historyDays))
        )
    }

    static func recordDetail(id: String, samples: [TrainingSample], now: Date, calendar: Calendar) -> TrainingSession? {
        let valid = samples.filter { $0.value.isFinite && $0.start <= now && $0.end <= now && $0.end >= $0.start && $0.ingestedAt <= now }
        let workouts = valid.filter { $0.type == TrainingTypes.workout && ($0.duration ?? 0) > 0 && ($0.duration ?? 0).isFinite && $0.end > $0.start }
        guard let workout = workouts.first(where: { $0.id == id }) else { return nil }
        let hearts = valid.filter { $0.type == TrainingTypes.heart && (25...230).contains($0.value) }
        let hrv = valid.filter { $0.type == TrainingTypes.hrv && $0.value > 0 && $0.value <= 500 }
        let nights = sleepNights(samples: valid.filter { $0.end < workout.start }, hearts: hearts,
            hrv: hrv, now: workout.start, calendar: calendar)
        return session(workout, hearts: hearts.filter { $0.source == workout.source }.sorted { $0.start < $1.start },
            resting: valid.filter { $0.type == TrainingTypes.resting }, nights: nights,
            workouts: deduplicatedWorkouts(workouts), calendar: calendar)
    }

    static func dayKey(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func median(_ values: [Double]) -> Double? {
        let v = values.filter(\.isFinite).sorted()
        guard !v.isEmpty else { return nil }
        return v.count.isMultiple(of: 2) ? (v[v.count / 2 - 1] + v[v.count / 2]) / 2 : v[v.count / 2]
    }

    private static func priority(_ sample: TrainingSample) -> Int {
        ["garmin": 100, "apple": 50, "xiaomiMijia": 30, "xiaomiSports": 30, "manual": 10][sample.origin] ?? 0
    }

    private static func deduplicatedWorkouts(_ workouts: [TrainingSample]) -> [TrainingSample] {
        var selected: [TrainingSample] = []
        for w in workouts.sorted(by: {
            priority($0) == priority($1) ? $0.id < $1.id : priority($0) > priority($1)
        }) {
            let duplicate = selected.contains { other in
                guard other.activityType == w.activityType,
                      abs(other.start.timeIntervalSince(w.start)) <= 120 else { return false }
                let overlap = min(other.end, w.end).timeIntervalSince(max(other.start, w.start))
                let shorter = min(other.end.timeIntervalSince(other.start), w.end.timeIntervalSince(w.start))
                return shorter > 0 && overlap / shorter >= 0.8
            }
            if !duplicate { selected.append(w) }
        }
        return selected
    }

    private static func session(_ w: TrainingSample, hearts: [TrainingSample], resting: [TrainingSample],
                                nights: [TrainingNight], workouts: [TrainingSample], calendar: Calendar) -> TrainingSession {
        let baselineStart = w.start.addingTimeInterval(-28 * 86_400)
        // Reference existed before the session. No later-day resting value leaks backward.
        let restingValues = resting.filter {
            !w.source.hasPrefix("unknown") && $0.source == w.source && $0.end < w.start
                && $0.start >= baselineStart && (30...120).contains($0.value)
        }
        let restingDays = Set(restingValues.map { dayKey($0.start, calendar) }).count
        let sleepValues = nights.filter {
            !w.source.hasPrefix("unknown") && $0.source == w.source && $0.end < w.start && $0.start >= baselineStart
                && $0.heartCount >= 12 && $0.heartSpanHours >= 1 && !$0.hasConflict
        }
        let useResting = restingDays >= 7
        let reference = useResting ? median(restingValues.map(\.value))
            : (sleepValues.count >= 7 ? median(sleepValues.compactMap(\.heartRate)) : nil)
        let method = useResting ? "此前28天同来源静息心率中位数（\(restingDays)天）"
            : "此前28天同来源睡眠心率中位数（\(sleepValues.count)晚）"
        // Source traces are sorted once per snapshot; only visit this session's local slice.
        let lower = lowerBound(hearts, w.start.addingTimeInterval(-15))
        let upper = lowerBound(hearts, w.end.addingTimeInterval(136))
        let sourceHearts = Array(hearts[lower..<upper])
        let values = sourceHearts.filter { $0.start >= w.start && $0.start < w.end }
        let elapsed = w.end.timeIntervalSince(w.start)
        let duration = min(w.duration ?? elapsed, elapsed)
        let ambiguousPause = elapsed - duration > max(60, elapsed * 0.1)
        let overlaps = workouts.contains {
            $0.id != w.id && min($0.end, w.end).timeIntervalSince(max($0.start, w.start)) > 30
        }
        var covered = 0.0, weightedHeart = 0.0, excess = 0.0
        // Collapse equal timestamps before integrating; several sources never get added together.
        let grouped = Dictionary(grouping: values, by: \.start)
        let points = grouped.keys.sorted().compactMap { time -> (Date, Double)? in
            median(grouped[time]!.map(\.value)).map { (time, $0) }
        }
        for (i, point) in points.enumerated() {
            let next = i + 1 < points.count ? points[i + 1].0 : w.end
            let seconds = min(maximumHeartGap, max(0, next.timeIntervalSince(point.0)))
            covered += seconds
            weightedHeart += point.1 * seconds
            if let reference { excess += max(0, point.1 - reference) * seconds / 60 }
        }
        let coverage = elapsed > 0 ? min(1, covered / elapsed) : 0
        let hasHeart = coverage >= 0.7 && !ambiguousPause && !overlaps
        var notes: [String] = []
        if coverage < 0.7 { notes.append("同来源心率覆盖不足70%，负荷未计算") }
        if reference == nil { notes.append("此前同来源静息/睡眠心率不足7天，负荷未计算") }
        if ambiguousPause { notes.append("暂停时段无法区分，负荷未计算") }
        if overlaps { notes.append("与其他训练重叠，负荷未计算") }
        let distance = w.distance.flatMap { $0.isFinite && $0 > 0 ? $0 / 1000 : nil }
        if w.activityType == 37 && distance == nil { notes.append("缺少距离，配速未计算") }
        // Signed observation, not the positive-only clinical/Apple HRR definition.
        func recovery(_ seconds: Double) -> Double? {
            let target = w.end.addingTimeInterval(seconds)
            guard !workouts.contains(where: { $0.id != w.id && $0.start <= target && $0.end > w.end }) else { return nil }
            func nearest(_ time: Date) -> Double? {
                sourceHearts.filter { abs($0.start.timeIntervalSince(time)) <= 15 }
                    .min { abs($0.start.timeIntervalSince(time)) < abs($1.start.timeIntervalSince(time)) }?.value
            }
            guard let finish = nearest(w.end), let later = nearest(target) else { return nil }
            return finish - later
        }
        return TrainingSession(id: w.id, start: w.start, end: w.end, activityType: w.activityType ?? 0,
            minutes: duration / 60, distanceKm: distance, source: w.source, sourceName: w.sourceName,
            averageHeartRate: hasHeart && covered > 0 ? weightedHeart / covered : nil,
            peakHeartRate: values.map(\.value).max(), heartCoverage: coverage,
            load: hasHeart && reference != nil ? excess : nil, restingReference: reference,
            restingMethod: method, recovery60: recovery(60), recovery120: recovery(120), notes: notes, energyKcal: w.energyKcal.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
    }

    private static func sleepNights(samples: [TrainingSample], hearts: [TrainingSample], hrv: [TrainingSample],
                                    now: Date, calendar: Calendar) -> [TrainingNight] {
        let sleep = samples.filter {
            $0.type == TrainingTypes.sleep && [0.0, 1, 2, 3, 4, 5].contains($0.value) && $0.end > $0.start
        }
        let today = calendar.startOfDay(for: now)
        return (0..<inputHistoryDays).compactMap { back -> TrainingNight? in
            let date = calendar.date(byAdding: .day, value: -back, to: today)!
            let previous = calendar.date(byAdding: .day, value: -1, to: date)!
            let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: previous)!
            // A morning snapshot never includes a future portion of today's window.
            let end = min(now, calendar.date(bySettingHour: 18, minute: 0, second: 0, of: date)!)
            let candidates = sleep.filter { $0.start < end && $0.end > start }
            let sources = Dictionary(grouping: candidates, by: \.source)
            guard let source = sources.keys.sorted(by: { a, b in
                let pa = priority(sources[a]![0]), pb = priority(sources[b]![0])
                if pa != pb { return pa > pb }
                let da = sources[a]!.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
                let db = sources[b]!.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
                return da == db ? a < b : da > db
            }).first else { return nil }
            let records = sources[source]!
            let boundaries = Set(records.flatMap { [max(start, $0.start), min(end, $0.end)] }).sorted()
            var intervals: [(Date, Date)] = [], conflicts: [(Date, Date)] = []
            for (a, b) in zip(boundaries, boundaries.dropFirst()) where b > a {
                let codes = Set(records.filter { $0.start < b && $0.end > a }.map { Int($0.value) }).subtracting([0])
                let detailed = codes.subtracting([1])
                let effective = detailed.isEmpty ? codes : detailed
                if effective.count > 1 { conflicts.append((a, b)) }
                if !effective.isEmpty && effective.isSubset(of: [1, 3, 4, 5]) { intervals.append((a, b)) }
            }
            // Group a main sleep episode; a daytime nap cannot be added as overnight recovery.
            var episodes: [[(Date, Date)]] = []
            for interval in intervals {
                if let last = episodes.last?.last, interval.0.timeIntervalSince(last.1) <= 90 * 60 {
                    episodes[episodes.count - 1].append(interval)
                } else { episodes.append([interval]) }
            }
            let overnight = episodes.filter { episode in
                guard let first = episode.first else { return false }
                let hour = calendar.component(.hour, from: first.0)
                return hour >= 18 || hour < 10
            }
            guard let main = overnight.max(by: { duration($0) < duration($1) }), duration(main) >= 90 * 60,
                  let first = main.first?.0, let last = main.last?.1 else { return nil }
            func inSleep(_ sample: TrainingSample) -> Bool {
                sample.source == source && sample.end <= last && main.contains { $0.0 <= sample.start && sample.start < $0.1 }
            }
            let nh = hrv.filter(inSleep), pulse = hearts.filter(inSleep)
            var stageHours: [Int: Double] = [:]
            for (a, b) in main {
                let codes = Set(records.filter { $0.start < b && $0.end > a }.map { Int($0.value) }).subtracting([0, 1])
                if codes.count == 1, let code = codes.first, [3, 4, 5].contains(code) {
                    stageHours[code, default: 0] += b.timeIntervalSince(a) / 3600
                }
            }
            func spanHours(_ values: [TrainingSample]) -> Double {
                guard let a = values.map(\.start).min(), let b = values.map(\.start).max() else { return 0 }
                return b.timeIntervalSince(a) / 3600
            }
            return TrainingNight(dayKey: dayKey(date, calendar), wakeDay: date, start: first, end: last,
                source: source, hours: duration(main) / 3600, hrv: median(nh.map(\.value)), hrvCount: nh.count,
                heartRate: median(pulse.map(\.value)), heartCount: pulse.count,
                hrvSpanHours: spanHours(nh), heartSpanHours: spanHours(pulse),
                hasConflict: conflicts.contains { $0.0 < last && $0.1 > first }, stageHours: stageHours)
        }.sorted { $0.wakeDay < $1.wakeDay }
    }

    private static func duration(_ intervals: [(Date, Date)]) -> Double {
        intervals.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
    }

    private static func lowerBound(_ samples: [TrainingSample], _ date: Date) -> Int {
        var low = 0, high = samples.count
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].start < date { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func intraday(hearts: [TrainingSample], workouts: [TrainingSample], now: Date) -> [TrainingRecoveryWindow] {
        let candidates = hearts.filter { sample in
            sample.start >= now.addingTimeInterval(-24 * 3600)
                && sample.motionContext != 2 && !workouts.contains {
                    sample.start >= $0.start && sample.start <= $0.end.addingTimeInterval(10 * 60)
                }
        }
        let sources = Dictionary(grouping: candidates, by: \.source)
        guard let source = sources.keys.sorted(by: { a, b in
            let pa = priority(sources[a]![0]), pb = priority(sources[b]![0])
            if pa != pb { return pa > pb }
            return sources[a]!.count == sources[b]!.count ? a < b : sources[a]!.count > sources[b]!.count
        }).first else { return [] }
        let filtered = sources[source]!
        let groups = Dictionary(grouping: filtered) { Int($0.start.timeIntervalSince1970 / 1800) }
        return groups.keys.sorted().compactMap { key in
            guard let samples = groups[key], samples.count >= 3, let heart = median(samples.map(\.value)) else { return nil }
            return TrainingRecoveryWindow(date: Date(timeIntervalSince1970: Double(key * 1800)), heartRate: heart, sampleCount: samples.count)
        }
    }

    private static func readinessHistory(nights: [TrainingNight], workouts: [TrainingSample],
        hearts: [String: [TrainingSample]], resting: [TrainingSample], now: Date, calendar: Calendar) -> [TrainingReadinessPoint] {
        let first = calendar.date(byAdding: .day, value: -(historyDays + 28 - 1), to: calendar.startOfDay(for: now))!
        let keyed = Dictionary(nights.map { ($0.dayKey, $0) }, uniquingKeysWith: { _, b in b })
        var result: [TrainingReadinessPoint] = []
        for offset in 0..<(historyDays + 28) {
            let day = calendar.date(byAdding: .day, value: offset, to: first)!
            let key = dayKey(day, calendar)
            guard let night = keyed[key] else {
                result.append(TrainingReadinessPoint(id: key, date: day,
                    assessment: readiness(nights: [], sessions: [], now: day)))
                continue
            }
            let anchor = night.end
            let priorNights = nights.filter { $0.end <= anchor }
            let priorWorkouts = deduplicatedWorkouts(workouts.filter { $0.end <= anchor })
            // Recompute the session evidence at this anchor so later overlapping workouts,
            // later HRR samples, and a different selection window cannot leak backward.
            let anchorHearts = hearts.mapValues { $0.filter { $0.end <= anchor } }
            let anchorResting = resting.filter { $0.end <= anchor }
            let priorSessions = priorWorkouts.filter { $0.start >= anchor.addingTimeInterval(-30 * 86400) }.map {
                session($0, hearts: anchorHearts[$0.source] ?? [],
                    resting: anchorResting, nights: priorNights,
                    workouts: priorWorkouts, calendar: calendar)
            }
            var value = readiness(nights: priorNights, sessions: priorSessions, now: anchor)
            let cutoff = calendar.date(byAdding: .day, value: -28, to: day)!
            let comparable = result.filter {
                $0.date >= cutoff && $0.assessment.source == value.source && $0.assessment.score != nil
            }
            value.referenceCount = comparable.count
            if comparable.count >= 14,
               let lower = TrainingTrendMath.quantile(comparable.compactMap { $0.assessment.score.map(Double.init) }, probability: 0.25),
               let upper = TrainingTrendMath.quantile(comparable.compactMap { $0.assessment.score.map(Double.init) }, probability: 0.75) {
                value.referenceRange = lower...upper
            }
            if value.score != nil, let previous = result.last(where: { $0.assessment.source == value.source && $0.assessment.score != nil }) {
                value.previousScore = previous.assessment.score
                value.previousDate = previous.date
            }
            result.append(TrainingReadinessPoint(id: key, date: anchor, assessment: value))
        }
        return result
    }

    private static func readiness(nights: [TrainingNight], sessions: [TrainingSession], now: Date) -> TrainingReadiness {
        guard let night = nights.last else {
            return TrainingReadiness(score: nil, credibility: "数据不足", baselineNights: 0,
                factors: [], missingReasons: ["尚无可识别的主睡眠记录"], observedAt: nil)
        }
        let base = nights.filter {
            $0.source == night.source && $0.end < night.start && $0.start >= night.start.addingTimeInterval(-42 * 86_400)
                && $0.qualifiesForBaseline
        }
        let baselineHRV = median(base.compactMap(\.hrv)), baselineHeart = median(base.compactMap(\.heartRate))
        let recent = sessions.filter { $0.end <= now && $0.end >= now.addingTimeInterval(-48 * 3600) }
        let loadBase = sessions.filter {
            $0.end < night.start && $0.start >= night.start.addingTimeInterval(-28 * 86_400)
        }
        let usableBase = loadBase.compactMap(\.load)
        let dailyLoad = usableBase.reduce(0, +) / 28
        let decayedLoad = recent.compactMap { session -> Double? in
            session.load.map { $0 * exp(-now.timeIntervalSince(session.end) / (24 * 3600)) }
        }.reduce(0, +)
        var missing: [String] = []
        if night.source.hasPrefix("unknown") { missing.append("睡眠来源标识不完整") }
        if now.timeIntervalSince(night.end) > 30 * 3600 { missing.append("主睡眠记录已超过30小时") }
        if night.hrvCount < 3 { missing.append("本晚HRV少于3个样本") }
        if night.heartCount < 12 { missing.append("本晚睡眠心率少于12个样本") }
        if night.hrvSpanHours < 1 { missing.append("本晚HRV采样跨度不足1小时") }
        if night.heartSpanHours < 1 { missing.append("本晚睡眠心率采样跨度不足1小时") }
        if night.hasConflict { missing.append("睡眠阶段存在冲突") }
        if base.count < 14 { missing.append("同来源有效夜间基线不足14晚（当前\(base.count)晚）") }
        let physiologyIsUsable = missing.isEmpty && baselineHRV != nil && baselineHeart != nil
        if recent.contains(where: { $0.load == nil }) { missing.append("最近48小时存在负荷无法计算的训练") }
        if usableBase.count < 4 || usableBase.count != loadBase.count || dailyLoad <= 0 {
            missing.append("此前28天完整训练负荷基线不足")
        }
        let sleepPenalty = min(40, max(0, 8 - night.hours) * 10)
        let hrvPenalty = baselineHRV.flatMap { baseline in
            night.hrv.map { min(25, max(0, 1 - $0 / baseline) * 70) }
        }
        let heartPenalty = baselineHeart.flatMap { baseline in
            night.heartRate.map { min(20, max(0, $0 - baseline) * 2) }
        }
        // HRV and sleep pulse are correlated observations of one autonomic domain.
        // Use the stronger normalized deviation, never add two penalties for that domain.
        let autonomicPenalty: Double? = {
            guard let hrvPenalty, let heartPenalty else { return nil }
            return max(hrvPenalty / 25, heartPenalty / 20) * 45
        }()
        let loadIsUsable = !recent.contains { $0.load == nil } && usableBase.count >= 4
            && usableBase.count == loadBase.count && dailyLoad > 0
        let loadPenalty = loadIsUsable ? min(15, decayedLoad / dailyLoad * 4) : nil
        let factors = [
            TrainingFactor(id: "sleep", title: "主睡眠", value: String(format: "%.1f 小时", night.hours), penalty: sleepPenalty,
                detail: "实验目标8小时；每不足1小时扣10分，上限40分。手表记录不证明完整睡眠。"),
            TrainingFactor(id: "autonomic", title: "夜间恢复信号", value: "\(number(night.hrv, suffix: " ms")) / \(number(night.heartRate, suffix: " bpm"))", penalty: autonomicPenalty,
                detail: "HRV \(night.hrvCount)个样本、跨\(String(format: "%.1f", night.hrvSpanHours))小时，基线\(number(baselineHRV, suffix: " ms"))；睡眠心率\(night.heartCount)个样本、跨\(String(format: "%.1f", night.heartSpanHours))小时，基线\(number(baselineHeart, suffix: " bpm"))。HRV低于基线的比例×70封顶25，心率高于基线每bpm×2封顶20；两者分别除以25和20，取较大值×45作为这一组扣分，不叠加。"),
            TrainingFactor(id: "load", title: "近期训练影响", value: recent.isEmpty ? "48小时内未记录训练" : "\(recent.count)次已记录训练", penalty: loadPenalty,
                detail: "最近48小时心率负荷按24小时时间尺度衰减，相对过去28天日均负荷×4，上限15分。时间衰减是模型推算。")
        ]
        let valid = missing.isEmpty && autonomicPenalty != nil && loadPenalty != nil
        let score = valid ? Int(max(0, min(100, 100 - sleepPenalty - autonomicPenalty! - loadPenalty!)).rounded()) : nil
        var possibleRange: ClosedRange<Int>?
        if physiologyIsUsable, !loadIsUsable, let autonomicPenalty {
            let upper = max(0, min(100, 100 - sleepPenalty - autonomicPenalty))
            possibleRange = Int(max(0, upper - 15).rounded())...Int(upper.rounded())
        }
        return TrainingReadiness(score: score, credibility: valid ? "覆盖可用 · 实验" : (possibleRange != nil ? "夜间覆盖可用 · 负荷不全" : "数据不足"),
            baselineNights: base.count, factors: factors, missingReasons: missing, observedAt: night.end,
            possibleRange: possibleRange, source: night.source)
    }

    private static func number(_ value: Double?, suffix: String) -> String {
        value.map { String(format: "%.1f", $0) + suffix } ?? "缺少数据"
    }

    private static func comparison(_ sessions: [TrainingSession]) -> TrainingRunComparison? {
        guard let last = sessions.first(where: { $0.isRun && $0.distanceKm != nil }), let distance = last.distanceKm,
              !last.source.hasPrefix("unknown") else { return nil }
        let comparable = sessions.filter {
            $0.isRun && $0.source == last.source && $0.averageHeartRate != nil
                && abs(($0.distanceKm ?? -100) - distance) <= distance * 0.1
        }
        guard comparable.count >= 4 else { return nil }
        let size = min(3, comparable.count / 2)
        let recent = Array(comparable.prefix(size)), earlier = Array(comparable.dropFirst(size).prefix(size))
        func pace(_ list: [TrainingSession]) -> Double {
            list.map(\.minutes).reduce(0, +) * 60 / list.compactMap(\.distanceKm).reduce(0, +)
        }
        return TrainingRunComparison(distanceKm: distance, recentPace: pace(recent), earlierPace: pace(earlier),
            recentHeart: median(recent.compactMap(\.averageHeartRate)), earlierHeart: median(earlier.compactMap(\.averageHeartRate)),
            recentCount: size, earlierCount: size,
            recentStart: recent.map(\.start).min(), recentEnd: recent.map(\.start).max(),
            earlierStart: earlier.map(\.start).min(), earlierEnd: earlier.map(\.start).max(), sourceName: last.sourceName, source: last.source)
    }
}
