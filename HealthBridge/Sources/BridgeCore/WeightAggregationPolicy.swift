import Foundation

/// A single raw weight observation.
public struct WeightObservation: Sendable, Codable, Equatable {
    public var id: String
    public var date: Date
    public var kilograms: Double
    public var source: String
    public var origin: String

    public init(
        id: String,
        date: Date,
        kilograms: Double,
        source: String,
        origin: String
    ) {
        self.id = id
        self.date = date
        self.kilograms = kilograms
        self.source = source
        self.origin = origin
    }
}

/// One occupied six-hour local clock slot.
public struct WeightStratum: Sendable, Codable, Equatable {
    public var slot: Int
    public var value: Double
    public var eventCount: Int

    public init(slot: Int, value: Double, eventCount: Int) {
        self.slot = slot
        self.value = value
        self.eventCount = eventCount
    }
}

/// Aggregated projection for one local calendar day.
public struct WeightDayProjection: Sendable, Codable, Equatable {
    public var day: String
    public var mean: Double?
    public var strata: [WeightStratum]
    public var acceptedCount: Int
    public var excludedGarminCount: Int
    public var excludedOtherCount: Int
    public var eventCount: Int
    public var sources: [String]

    public init(
        day: String,
        mean: Double?,
        strata: [WeightStratum],
        acceptedCount: Int,
        excludedGarminCount: Int,
        excludedOtherCount: Int,
        eventCount: Int,
        sources: [String]
    ) {
        self.day = day
        self.mean = mean
        self.strata = strata
        self.acceptedCount = acceptedCount
        self.excludedGarminCount = excludedGarminCount
        self.excludedOtherCount = excludedOtherCount
        self.eventCount = eventCount
        self.sources = sources
    }
}

/// Foundation-only deterministic weight aggregation policy.
public enum WeightAggregationPolicy {
    public static let version: String = "weight-time-strata-v1"

    public static func displayKilograms(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        guard abs(value) <= Double.greatestFiniteMagnitude / 10 else { return String(value) }
        return String(format: "%.1f", (value * 10).rounded(.toNearestOrAwayFromZero) / 10)
    }

    private static let eventSpanSeconds: TimeInterval = 1800
    private static let slotCount: Int = 4
    private static let slotSeconds: TimeInterval = 6 * 3600

    private struct Event {
        var value: Double
        var time: Date
        var source: String
    }

    public static func project(
        observations: [WeightObservation],
        day: Date,
        calendar: Calendar
    ) -> WeightDayProjection {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let dayKey = formatDay(dayStart, calendar: calendar)

        // 1. Valid finite positive observations only.
        let valid = observations.filter { $0.kilograms.isFinite && $0.kilograms > 0 }

        // 2. Raw observations whose original local date falls within the requested day.

        // 3. Drop duplicate ids deterministically: keep the first occurrence in
        //    (time, id) order so the result is invariant under input shuffling.
        let sortedRaw = valid.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.id != $1.id { return $0.id < $1.id }
            if $0.source != $1.source { return $0.source < $1.source }
            if $0.origin != $1.origin { return $0.origin < $1.origin }
            return $0.kilograms < $1.kilograms
        }
        var seenIDs: Set<String> = []
        var deduped: [WeightObservation] = []
        deduped.reserveCapacity(sortedRaw.count)
        for obs in sortedRaw where seenIDs.insert(obs.id).inserted {
            deduped.append(obs)
        }

        // 4. Classification of raw observations.
        var excludedGarminCount = 0
        var excludedOtherCount = 0
        var accepted: [WeightObservation] = []
        for obs in deduped {
            if isGarmin(obs) {
                if calendar.isDate(obs.date, inSameDayAs: dayStart) { excludedGarminCount += 1 }
            } else if isAccepted(obs) {
                accepted.append(obs)
            } else {
                if calendar.isDate(obs.date, inSameDayAs: dayStart) { excludedOtherCount += 1 }
            }
        }
        let acceptedCount = accepted.filter { calendar.isDate($0.date, inSameDayAs: dayStart) }.count

        // 5. Group accepted observations per exact source into time-anchored events.
        //    This happens before date filtering; an event is assigned once by its
        //    median timestamp.
        var events: [Event] = []
        let grouped = Dictionary(grouping: accepted, by: { $0.source })
        for source in grouped.keys.sorted() {
            guard let group = grouped[source] else { continue }
            let ordered = group.sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.id < $1.id
            }
            var bucket: [WeightObservation] = []
            for obs in ordered {
                if let anchor = bucket.first?.date,
                   obs.date.timeIntervalSince(anchor) > eventSpanSeconds {
                    events.append(makeEvent(from: bucket, source: source))
                    bucket.removeAll(keepingCapacity: true)
                }
                bucket.append(obs)
            }
            if !bucket.isEmpty {
                events.append(makeEvent(from: bucket, source: source))
            }
        }

        // 6. Assign events to the requested local day via their median timestamp.
        let dayEvents = events.filter {
            $0.time >= dayStart && $0.time < dayEnd
        }

        // 7. Bucket events into four six-hour local clock slots.
        var slotBuckets = [[Double]](repeating: [], count: slotCount)
        for event in dayEvents {
            let slot = calendar.component(.hour, from: event.time) / 6
            guard slot >= 0, slot < slotCount else { continue }
            slotBuckets[slot].append(event.value)
        }

        var strata: [WeightStratum] = []
        strata.reserveCapacity(slotCount)
        for slot in 0..<slotCount where !slotBuckets[slot].isEmpty {
            strata.append(
                WeightStratum(
                    slot: slot,
                    value: median(slotBuckets[slot]),
                    eventCount: slotBuckets[slot].count
                )
            )
        }

        // 8. Daily mean across occupied slots only, scaled to avoid overflow.
        let mean: Double? = strata.isEmpty
            ? nil
            : scaledMean(strata.map { $0.value })

        let sources = dayEvents.map { $0.source }.sorted().uniqueSorted()

        return WeightDayProjection(
            day: dayKey,
            mean: mean,
            strata: strata,
            acceptedCount: acceptedCount,
            excludedGarminCount: excludedGarminCount,
            excludedOtherCount: excludedOtherCount,
            eventCount: dayEvents.count,
            sources: sources
        )
    }

    // MARK: - Helpers

    /// Raw evidence remains readable; this reason also labels records in Mac queries.
    public static func exclusionReason(source: String, origin: String) -> String? {
        if containsGarmin(source) || containsGarmin(origin) { return "garmin_manual_weight" }
        if origin == "xiaomiMijia" || source.range(of: "mijia", options: [.caseInsensitive]) != nil || source.contains("米家") { return nil }
        return "unconfirmed_scale_source"
    }

    private static func isGarmin(_ observation: WeightObservation) -> Bool {
        return containsGarmin(observation.source) || containsGarmin(observation.origin)
    }

    private static func containsGarmin(_ text: String) -> Bool {
        return text.range(of: "garmin", options: [.caseInsensitive]) != nil
    }

    private static func isAccepted(_ observation: WeightObservation) -> Bool {
        return exclusionReason(source: observation.source, origin: observation.origin) == nil
    }

    private static func makeEvent(
        from bucket: [WeightObservation],
        source: String
    ) -> Event {
        return Event(
            value: median(bucket.map { $0.kilograms }),
            time: medianTimestamp(bucket.map { $0.date }),
            source: source
        )
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return sorted[mid - 1] / 2 + sorted[mid] / 2
    }

    private static func medianTimestamp(_ values: [Date]) -> Date {
        guard !values.isEmpty else { return Date(timeIntervalSince1970: 0) }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        // Median of an even count: average of the two central timestamps,
        // computed with a scaled offset to avoid overflow.
        let lower = sorted[mid - 1]
        let upper = sorted[mid]
        return lower.addingTimeInterval(upper.timeIntervalSince(lower) / 2)
    }

    /// Arithmetic mean computed with running offset scaling so that a large
    /// number of large finite values cannot overflow the running sum.
    private static func scaledMean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let scale = values.max() ?? 1
        return scale * (values.reduce(0) { $0 + $1 / scale } / Double(values.count))
    }

    private static func formatDay(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private extension Sequence where Element == String {
    func uniqueSorted() -> [String] {
        return Array(Set(self)).sorted()
    }
}
