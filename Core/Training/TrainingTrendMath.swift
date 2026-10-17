import Foundation

internal enum TrainingTrendMath {
    /// Percent change of `current` relative to `baseline`.
    /// Returns nil unless both inputs are finite, baseline > 0, and the result is finite.
    static func percentChange(current: Double, baseline: Double) -> Double? {
        guard current.isFinite, baseline.isFinite, baseline > 0 else { return nil }
        let result = (current - baseline) / baseline * 100.0
        return result.isFinite ? result : nil
    }

    /// Linear-interpolated quantile (type 7) over the finite values in `values`.
    /// Returns nil if no finite values remain or probability is not a finite value in 0...1.
    static func quantile(_ values: [Double], probability: Double) -> Double? {
        guard probability.isFinite, (0.0...1.0).contains(probability) else { return nil }
        let sorted = values.filter { $0.isFinite }.sorted()
        guard !sorted.isEmpty else { return nil }
        if sorted.count == 1 { return sorted[0] }

        let n = sorted.count
        let position = (Double(n) - 1.0) * probability
        guard position.isFinite else { return nil }

        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        guard lowerIndex >= 0, upperIndex < n else { return nil }

        if lowerIndex == upperIndex { return sorted[lowerIndex] }

        let fraction = position - Double(lowerIndex)
        let lower = sorted[lowerIndex]
        let upper = sorted[upperIndex]
        // Opposite-sign extremes can overflow their difference.
        let result = lower.sign != upper.sign
            ? lower * (1 - fraction) + upper * fraction
            : lower + fraction * (upper - lower)
        return result.isFinite ? result : nil
    }
}
