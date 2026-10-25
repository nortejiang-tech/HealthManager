import Foundation

struct WorkoutEvent: Sendable {
    var selected: TrainingSample
    let contributors: [TrainingSample]
    var notes: [String]
    /// Persisted user selection attached to this event group. nil means the automatic decision stands.
    var choice: WorkoutRecordChoice? = nil
    var sourceIDs: Set<String> { Set(contributors.map(\.source)) }
    /// True only when the persisted choice still names this event's primary record.
    var isManuallySelected: Bool {
        guard let chosen = choice?.selectedID else { return false }
        return chosen == selected.id
    }
}

/// Persistent user selection for one matched workout group. Pure value; no database access here.
struct WorkoutRecordChoice: Codable, Hashable, Sendable {
    let id: String
    /// nil means an explicit decision to fall back to the automatic selection.
    let selectedID: String?
    let memberIDs: [String]
    let updatedAt: Double
}

enum WorkoutEventResolver {
    static let policyVersion = "workout-record-choice-v2"
    static func events(_ workouts: [TrainingSample], choices: [WorkoutRecordChoice] = []) -> [WorkoutEvent] {
        let ordered = workouts.filter { $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite && $0.end > $0.start && ($0.duration ?? 0) > 0 && $0.duration?.isFinite == true && $0.value.isFinite }.sorted {
            let a = SampleSourcePolicy.priority($0.origin), b = SampleSourcePolicy.priority($1.origin)
            return a == b ? $0.id < $1.id : a > b
        }
        var groups: [[TrainingSample]] = []
        for sample in ordered {
            if let i = groups.firstIndex(where: { group in group.contains { matches($0, sample) } }) { groups[i].append(sample) }
            else { groups.append([sample]) }
        }
        return groups.map { records in
            let memberIDs = Set(records.map(\.id))
            // Grouping never depends on the preference; a choice is attached to a group only through
            // member-ID intersection, and the freshest finite updatedAt wins with a deterministic id tie-break.
            let choice = choices
                .filter { $0.updatedAt.isFinite && $0.memberIDs.contains(where: { id in memberIDs.contains(id) }) }
                .min {
                    let a = $0.updatedAt, b = $1.updatedAt
                    // Guard NaN/nonfinite timestamps: order them last, never let them win.
                    let aValid = a.isFinite, bValid = b.isFinite
                    if aValid != bValid { return aValid }
                    if a != b { return a > b }
                    return $0.id < $1.id
                }
            var selected = records[0]
            var notes: [String] = []
            let manual: Bool
            if let choice {
                if let chosenID = choice.selectedID, let match = records.first(where: { $0.id == chosenID }) {
                    // Manual selection: keep the user's record exactly as stored; no complete-window fallback.
                    selected = match
                    manual = true
                } else {
                    // Missing or stale selection: keep the choice attached for the warning note and stay automatic.
                    selected = records[0]
                    manual = false
                }
            } else {
                manual = false
            }
            if records.count > 1 {
                let origins = Set(records.map(\.origin))
                notes.append(origins.contains("garmin") && origins.contains("apple")
                    ? (manual ? "双端运动已匹配，统计一次；采用手动选定主记录" : "双端运动已匹配，统计一次；优先参考佳明有效数据")
                    : "多条运动记录已匹配，仅统计一次；记录条数不代表设备数量")
            }
            let complete = records.max {
                let a = $0.end.timeIntervalSince($0.start), b = $1.end.timeIntervalSince($1.start)
                return a == b ? $0.id > $1.id : a < b
            }!
            let primaryElapsed = selected.end.timeIntervalSince(selected.start)
            let longest = complete.end.timeIntervalSince(complete.start)
            if !(selected.end > selected.start) || !primaryElapsed.isFinite || !longest.isFinite {
                // Guard invalid/NaN spans: never let a broken window drive the automatic fallback.
                selected.start = complete.start; selected.end = complete.end; selected.duration = complete.duration
            } else if manual {
                // Manual note first: the user's decision governs this record.
                notes.insert("已手动选定：主记录来源 \(selected.sourceName)", at: 0)
                // Never replace a shorter manual window with the complete Apple record; only fill
                // genuinely missing or invalid metrics. Zero is an observed value and must remain.
                if selected.distance == nil || selected.distance.map({ !$0.isFinite || $0 < 0 }) == true,
                   let other = records.first(where: { ($0.distance ?? -1) >= 0 && ($0.distance ?? -1).isFinite }) {
                    selected.distance = other.distance
                    notes.append("距离缺失或无效，由 \(other.sourceName) 补位")
                }
                if selected.energyKcal == nil || selected.energyKcal.map({ !$0.isFinite || $0 < 0 }) == true,
                   let other = records.first(where: { ($0.energyKcal ?? -1) >= 0 && ($0.energyKcal ?? -1).isFinite }) {
                    selected.energyKcal = other.energyKcal
                    notes.append("运动消耗缺失或无效，由 \(other.sourceName) 补位")
                }
            } else if selected.origin == "garmin", complete.origin == "apple", primaryElapsed < longest * 0.9 {
                // A substantially shorter Garmin auto-detected event cannot define the full session.
                selected.start = complete.start; selected.end = complete.end; selected.duration = complete.duration
                selected.distance = complete.distance; selected.energyKcal = complete.energyKcal
                notes.append("佳明运动窗口不全，时长/距离/运动消耗由 Apple 完整记录补位")
            } else {
                if selected.distance == nil || selected.distance.map({ !$0.isFinite || $0 <= 0 }) == true {
                    if let other = records.first(where: { ($0.distance ?? 0) > 0 && ($0.distance ?? 0).isFinite }) {
                        selected.distance = other.distance; notes.append("距离由 \(other.sourceName) 补全")
                    }
                }
                if selected.energyKcal == nil, let other = records.first(where: { ($0.energyKcal ?? -1) >= 0 && ($0.energyKcal ?? -1).isFinite }) {
                    selected.energyKcal = other.energyKcal; notes.append("运动消耗由 \(other.sourceName) 补全")
                }
            }
            if let choice, choice.selectedID == nil {
                // Explicit reset to automatic: keep the choice visible, do not resurrect an old record.
                notes.append("已恢复自动选择")
            } else if let choice, choice.selectedID != nil, !manual {
                notes.append("手动选定记录不可用，已回退自动判定")
            }
            let distances = records.compactMap { $0.distance }.filter { $0.isFinite && $0 > 0 }
            if let low = distances.min(), let high = distances.max(), high - low > max(100, high * 0.1) {
                notes.append("双端距离存在差异，保留主值与原始记录；未取平均")
            }
            return WorkoutEvent(selected: selected, contributors: records, notes: notes, choice: choice)
        }.sorted { $0.selected.start == $1.selected.start ? $0.selected.id < $1.selected.id : $0.selected.start < $1.selected.start }
    }
    static func matches(_ a: TrainingSample, _ b: TrainingSample) -> Bool {
        guard a.activityType == b.activityType else { return false }
        let short = min(a.end.timeIntervalSince(a.start), b.end.timeIntervalSince(b.start))
        let overlap = min(a.end, b.end).timeIntervalSince(max(a.start, b.start))
        // Experimental matching tolerance; retain original records and expose provenance.
        return short > 0 && overlap / short >= 0.8
            && abs(a.start.timeIntervalSince(b.start)) <= max(120, min(600, short * 0.25))
    }
    static func hearts(_ all: [TrainingSample], for event: WorkoutEvent, sortedByStart: Bool = false) -> [TrainingSample] {
        // Performance: every production consumer (TrainingCalculator.session) binary-slices this result
        // in the half-open window [start - 30s, end + 136s). Discard out-of-window samples before
        // sorting so a multi-month history is not sorted per session/anchor. Same caller window.
        let lower = event.selected.start.addingTimeInterval(-30)
        let upper = event.selected.end.addingTimeInterval(136)
        let candidates = sortedByStart
            ? all[lowerBound(all, lower)..<lowerBound(all, upper)] : all[...]
        let sources = event.sourceIDs
        return candidates.filter {
            $0.start >= lower && $0.start < upper
                && (sources.contains($0.source)
                || (event.selected.origin == "apple" && $0.origin == "garmin")
                || (event.selected.origin == "garmin" && $0.origin == "apple"))
        }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
    private static func lowerBound(_ samples: [TrainingSample], _ date: Date) -> Int {
        var low = 0, high = samples.count
        while low < high {
            let middle = low + (high - low) / 2
            if samples[middle].start < date { low = middle + 1 } else { high = middle }
        }
        return low
    }
    static func observation(_ sample: TrainingSample) -> SampleSourcePolicy.Observation {
        .init(id: sample.id, source: sample.source, origin: sample.origin,
              start: sample.start, end: sample.end, value: sample.value)
    }
}
