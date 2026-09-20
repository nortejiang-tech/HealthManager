import Foundation

/// Errors raised for unusable sleep-window input.
public enum BridgeCalendarWindowError: Error, Equatable {
    case invalidWakeDate(String)
    case unknownTimeZone(String)
}

/// Pure helper that maps a "wake up on this date" request to the local sleep window
/// that precedes it: 18:00 on the day before the wake date through 18:00 on the
/// wake date itself.
public enum BridgeCalendarWindow {

    /// Strict textual format for the wake date.
    private static let dateFormat = "yyyy-MM-dd"

    /// Resolve the sleep window for a wake date in an IANA time zone.
    ///
    /// Calendar arithmetic is done with civil-calendar components rather than fixed
    /// second counts: the previous calendar day is obtained with `date(byAdding:)`
    /// and each 18:00 boundary is built by setting clock components on that day.
    /// A DST transition inside the window therefore yields a genuine 23h or 25h
    /// interval instead of a hard-coded 86400 +/- offset.
    public static func sleep(wakeDate: String, timeZone: String) throws -> DateInterval {
        guard let calendar = calendar(for: timeZone) else {
            throw BridgeCalendarWindowError.unknownTimeZone(timeZone)
        }
        guard let wakeDayStart = startOfDay(for: wakeDate, in: calendar) else {
            throw BridgeCalendarWindowError.invalidWakeDate(wakeDate)
        }
        // Previous calendar date, computed by the calendar so month/year rollover
        // and DST are handled for us.
        guard let beginDate = calendar.date(byAdding: .day, value: -1, to: wakeDayStart) else {
            throw BridgeCalendarWindowError.invalidWakeDate(wakeDate)
        }
        // Set the wall-clock components explicitly; 18:00 may not exist or may be
        // ambiguous across a DST shift, so resolve through the calendar.
        guard let start = settingTime(on: beginDate, hour: 18, in: calendar),
              let end = settingTime(on: wakeDayStart, hour: 18, in: calendar) else {
            throw BridgeCalendarWindowError.invalidWakeDate(wakeDate)
        }
        return DateInterval(start: start, end: end)
    }

    private static func calendar(for timeZone: String) -> Calendar? {
        guard !timeZone.isEmpty, let zone = TimeZone(identifier: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = 1
        return calendar
    }

    /// Parse `yyyy-MM-dd` strictly, rejecting anything the calendar would silently
    /// normalize (e.g. 2026-02-30 -> 2026-03-02) or reformat.
    private static func startOfDay(for text: String, in calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = dateFormat
        formatter.isLenient = false
        guard let date = formatter.date(from: text) else { return nil }
        // Round-trip guards against missing zero padding, extra text and any
        // lenient reinterpretation the formatter might still allow.
        guard formatter.string(from: date) == text else { return nil }
        // Guard against calendar normalization of an impossible day.
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.year != nil, components.month != nil, components.day != nil,
              let reconstructed = calendar.date(from: components),
              calendar.isDate(reconstructed, inSameDayAs: date) else { return nil }
        return calendar.startOfDay(for: date)
    }

    /// Build the requested wall-clock time on the given day.
    private static func settingTime(on day: Date, hour: Int, in calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = 0
        components.second = 0
        components.nanosecond = 0
        return calendar.date(from: components)
    }
}
