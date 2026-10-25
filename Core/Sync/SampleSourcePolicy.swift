import Foundation

enum SampleSourcePolicy {
    struct Observation {
        let id: String
        let source: String
        let origin: String
        let start: Date
        let end: Date
        let value: Double
    }

    struct Segment {
        let start: Date
        let end: Date
        let observation: Observation
    }

    static func priority(_ origin: String) -> Int {
        switch origin {
        case "garmin": return 100
        case "apple": return 50
        case "xiaomiMijia", "xiaomiSports": return 30
        case "hutool": return 20
        case "manual": return 10
        default: return 0
        }
    }

    static func resolve(
        _ observations: [Observation],
        from: Date,
        to: Date,
        maximumHold: TimeInterval = 30,
        preferredSource: String? = nil
    ) -> [Segment] {
        guard to > from, maximumHold.isFinite, maximumHold > 0 else { return [] }

        let ordered = observations.filter {
            $0.value.isFinite && $0.end >= $0.start && $0.start < to
        }.sorted {
            if $0.source != $1.source { return $0.source < $1.source }
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.id != $1.id { return $0.id < $1.id }
            if $0.end != $1.end { return $0.end < $1.end }
            if $0.origin != $1.origin { return $0.origin < $1.origin }
            return $0.value < $1.value
        }

        var nextLater = Array<Date?>(repeating: nil, count: ordered.count)
        var groupStart = 0
        while groupStart < ordered.count {
            var groupEnd = groupStart + 1
            while groupEnd < ordered.count && ordered[groupEnd].source == ordered[groupStart].source {
                groupEnd += 1
            }
            var cursor = groupEnd
            var laterTimestamp: Date?
            while cursor > groupStart {
                var bucketStart = cursor - 1
                let timestamp = ordered[bucketStart].start
                while bucketStart > groupStart && ordered[bucketStart - 1].start == timestamp {
                    bucketStart -= 1
                }
                for index in bucketStart..<cursor { nextLater[index] = laterTimestamp }
                laterTimestamp = timestamp
                cursor = bucketStart
            }
            groupStart = groupEnd
        }

        var coverage: [(observation: Observation, start: Date, end: Date)] = []
        coverage.reserveCapacity(ordered.count)
        for (index, observation) in ordered.enumerated() {
            var end = observation.start.addingTimeInterval(maximumHold)
            if observation.end > observation.start { end = min(end, observation.end) }
            if let next = nextLater[index] { end = min(end, next) }
            let clippedStart = max(observation.start, from)
            let clippedEnd = min(end, to)
            if clippedEnd > clippedStart {
                coverage.append((observation, clippedStart, clippedEnd))
            }
        }

        let boundaries = Array(Set(coverage.flatMap { [$0.start, $0.end] })).sorted()
        guard boundaries.count >= 2 else { return [] }

        var startsAt: [Date: [Int]] = [:]
        startsAt.reserveCapacity(coverage.count)
        for index in coverage.indices { startsAt[coverage[index].start, default: []].append(index) }
        var heap: [Int] = []
        heap.reserveCapacity(coverage.count)
        func outranks(_ lhs: Int, _ rhs: Int) -> Bool {
            let left = coverage[lhs]
            let right = coverage[rhs]
            if preferred(left, right, preferredSource: preferredSource) { return true }
            if preferred(right, left, preferredSource: preferredSource) { return false }
            return lhs < rhs
        }
        func push(_ value: Int) {
            heap.append(value)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard outranks(heap[child], heap[parent]) else { break }
                heap.swapAt(child, parent)
                child = parent
            }
        }
        func pop() {
            guard !heap.isEmpty else { return }
            if heap.count == 1 { heap.removeLast(); return }
            heap[0] = heap.removeLast()
            var parent = 0
            while true {
                let left = parent * 2 + 1
                let right = left + 1
                var best = parent
                if left < heap.count && outranks(heap[left], heap[best]) { best = left }
                if right < heap.count && outranks(heap[right], heap[best]) { best = right }
                guard best != parent else { break }
                heap.swapAt(parent, best)
                parent = best
            }
        }

        var result: [Segment] = []
        for index in 0..<(boundaries.count - 1) {
            let start = boundaries[index]
            let end = boundaries[index + 1]
            for candidate in startsAt[start] ?? [] { push(candidate) }
            while let top = heap.first, coverage[top].end <= start { pop() }
            guard end > start, let top = heap.first else { continue }
            let winner = coverage[top]

            if let previous = result.last,
               previous.end == start,
               previous.observation.id == winner.observation.id,
               previous.observation.source == winner.observation.source {
                result[result.count - 1] = Segment(
                    start: previous.start,
                    end: end,
                    observation: previous.observation
                )
            } else {
                result.append(Segment(start: start, end: end, observation: winner.observation))
            }
        }
        return result
    }

    private static func preferred(
        _ lhs: (observation: Observation, start: Date, end: Date),
        _ rhs: (observation: Observation, start: Date, end: Date),
        preferredSource: String? = nil
    ) -> Bool {
        let left = lhs.observation
        let right = rhs.observation
        // An exact preferred-source match ranks ahead of origin priority for overlapping observations.
        // Sources that merely differ do not get promoted, so gaps keep the original origin rules.
        if let preferredSource, !preferredSource.isEmpty {
            let leftMatches = left.source == preferredSource
            let rightMatches = right.source == preferredSource
            if leftMatches != rightMatches { return leftMatches }
        }
        let leftPriority = priority(left.origin)
        let rightPriority = priority(right.origin)
        if leftPriority != rightPriority { return leftPriority > rightPriority }
        if left.start != right.start { return left.start > right.start }
        if left.source != right.source { return left.source < right.source }
        return left.id < right.id
    }
}
