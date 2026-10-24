import Foundation

struct WorkoutEvent {
    var selected: TrainingSample
    let contributors: [TrainingSample]
    var notes: [String]
    var sourceIDs: Set<String> { Set(contributors.map(\.source)) }
}

enum WorkoutEventResolver {
    static let policyVersion = "garmin-first-apple-completion-v1"
    static func events(_ workouts: [TrainingSample]) -> [WorkoutEvent] {
        let ordered = workouts.filter { $0.end > $0.start && ($0.duration ?? 0) > 0 }.sorted {
            let a = SampleSourcePolicy.priority($0.origin), b = SampleSourcePolicy.priority($1.origin)
            return a == b ? $0.id < $1.id : a > b
        }
        var groups: [[TrainingSample]] = []
        for sample in ordered {
            if let i = groups.firstIndex(where: { group in group.contains { matches($0, sample) } }) { groups[i].append(sample) }
            else { groups.append([sample]) }
        }
        return groups.map { records in
            var selected = records[0]
            var notes: [String] = []
            let complete = records.max {
                let a = $0.end.timeIntervalSince($0.start), b = $1.end.timeIntervalSince($1.start)
                return a == b ? $0.id > $1.id : a < b
            }!
            if records.count > 1 {
                let origins = Set(records.map(\.origin))
                notes.append(origins.contains("garmin") && origins.contains("apple")
                    ? "双端运动已匹配，统计一次；优先参考佳明有效数据"
                    : "多条运动记录已匹配，仅统计一次；记录条数不代表设备数量")
            }
            let primaryElapsed = selected.end.timeIntervalSince(selected.start)
            let longest = complete.end.timeIntervalSince(complete.start)
            // A substantially shorter Garmin auto-detected event cannot define the full session.
            if selected.origin == "garmin", complete.origin == "apple", primaryElapsed < longest * 0.9 {
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
            let distances = records.compactMap { $0.distance }.filter { $0.isFinite && $0 > 0 }
            if let low = distances.min(), let high = distances.max(), high - low > max(100, high * 0.1) {
                notes.append("双端距离存在差异，保留主值与原始记录；未取平均")
            }
            return WorkoutEvent(selected: selected, contributors: records, notes: notes)
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
