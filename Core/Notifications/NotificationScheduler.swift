import Foundation
import UserNotifications

/// Local notification scheduling for medication reminders (v2).
///
/// Storage model: each `MedicationPlan.scheduleJson` decodes to a `Schedule`. We register
/// one repeating calendar-trigger UNNotificationRequest per (weekday, time) combo,
/// identifier = `med-plan-<planId>-<weekday>-<hour>-<minute>` so re-scheduling
/// replaces previous requests without orphaning them.
///
/// All operations are best-effort: failure to schedule does not block plan save.
actor NotificationScheduler {

    static let shared = NotificationScheduler()

    private init() {}

    /// Plan-level reminder definition stored as JSON in `medication_plans.schedule_json`.
    struct Schedule: Codable, Equatable {
        /// 1 = Sunday … 7 = Saturday (matches `Calendar.dateComponents` weekday).
        var weekdays: [Int]
        /// 0–23
        var hour: Int
        /// 0–59
        var minute: Int

        var isValid: Bool {
            !weekdays.isEmpty
                && weekdays.allSatisfy { (1...7).contains($0) }
                && (0...23).contains(hour)
                && (0...59).contains(minute)
        }

        static let defaultMorning = Schedule(weekdays: [1, 2, 3, 4, 5, 6, 7], hour: 9, minute: 0)
    }

    // MARK: - Permission

    /// Asks the user for notification permission. Returns `true` if granted (or already granted).
    func requestAuthorization() async -> Bool {
        do {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                return true
            case .denied:
                return false
            case .notDetermined:
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            @unknown default:
                return false
            }
        } catch {
            AppLogger.shared.error("Notification auth failed: \(error.localizedDescription)")
            return false
        }
    }

    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    // MARK: - Scheduling

    /// Schedules (or re-schedules) all notifications for a plan. Removes prior requests
    /// for the same plan first so toggling weekdays doesn't leave stale notifications.
    func schedule(planId: Int64, name: String, dosageMg: Double?, schedule: Schedule) async {
        await removeAll(forPlanId: planId)
        guard schedule.isValid else { return }

        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "用药提醒"
        if let mg = dosageMg, mg > 0 {
            content.body = "\(name) · \(formatted(mg)) mg"
        } else {
            content.body = name
        }
        content.sound = .default
        content.userInfo = ["planId": planId]

        for weekday in schedule.weekdays {
            var comps = DateComponents()
            comps.weekday = weekday
            comps.hour = schedule.hour
            comps.minute = schedule.minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            let id = identifier(planId: planId, weekday: weekday, hour: schedule.hour, minute: schedule.minute)
            let req = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            do {
                try await center.add(req)
            } catch {
                AppLogger.shared.error("Notif schedule failed (\(id)): \(error.localizedDescription)")
            }
        }
    }

    /// Removes every pending notification for the given plan id.
    func removeAll(forPlanId planId: Int64) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let prefix = "med-plan-\(planId)-"
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    // MARK: - Helpers

    private func identifier(planId: Int64, weekday: Int, hour: Int, minute: Int) -> String {
        "med-plan-\(planId)-\(weekday)-\(hour)-\(minute)"
    }

    private func formatted(_ mg: Double) -> String {
        if mg == mg.rounded() { return String(format: "%.0f", mg) }
        return String(format: "%.2f", mg)
    }
}

extension NotificationScheduler.Schedule {
    /// Encode to JSON for storage in `medication_plans.schedule_json`.
    func toJson() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode from JSON; returns nil on malformed input.
    static func fromJson(_ json: String?) -> NotificationScheduler.Schedule? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(NotificationScheduler.Schedule.self, from: data)
    }
}
