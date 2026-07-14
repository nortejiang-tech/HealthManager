import Foundation

struct TodayEvidencePresentation: Equatable {
    enum QualityPillStyle: Equatable {
        case unreconciled
        case reconciledNoAlerts
        case hasAlerts
    }

    struct SummaryText: Equatable {
        let valueText: String
        let detailText: String?
        let accessibilityLabel: String
    }

    struct TimelineRow: Identifiable, Equatable {
        enum Kind: Equatable {
            case meal
            case medication
        }

        let id: String
        let kind: Kind
        let timeText: String
        let title: String
        let primaryText: String
        let detailText: String?
        let metadataText: String?
        let accessibilityLabel: String
    }

    struct SourceCoverageRow: Identifiable, Equatable {
        let id: String
        let title: String
        let detailText: String
        let accessibilityLabel: String
    }

    let calendar: Calendar
    let locale: Locale
    let snapshot: TodayEvidenceSnapshot

    init(
        calendar: Calendar = .current,
        locale: Locale = .current,
        snapshot: TodayEvidenceSnapshot
    ) {
        self.calendar = calendar
        self.locale = locale
        self.snapshot = snapshot
    }

    static func resolvedInterfaceLocale(
        environmentLocale: Locale,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Locale {
        guard let identifier = preferredLanguages.first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty
        else {
            return environmentLocale
        }

        let preferredLocale = Locale(identifier: identifier)
        guard preferredLocale.region == nil,
              let region = environmentLocale.region?.identifier,
              !region.isEmpty
        else {
            return preferredLocale
        }
        return Locale(identifier: "\(identifier)_\(region)")
    }

    var headerTitle: String {
        "今日"
    }

    var dateText: String {
        localizedDateFormatter(template: "MMMdEEEE").string(from: snapshot.dayStart)
    }

    var sleepSummary: SummaryText {
        guard let seconds = validatedNonnegative(snapshot.dailyAggregate.asleepSeconds) else {
            return SummaryText(
                valueText: "暂无睡眠汇总",
                detailText: nil,
                accessibilityLabel: "当天睡眠汇总，暂无睡眠汇总"
            )
        }

        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let value: String
        if hours > 0, minutes > 0 {
            value = "\(hours) 小时 \(minutes) 分钟"
        } else if hours > 0 {
            value = "\(hours) 小时"
        } else {
            value = "\(minutes) 分钟"
        }
        return SummaryText(
            valueText: value,
            detailText: nil,
            accessibilityLabel: "当天睡眠汇总，\(value)"
        )
    }

    var activitySummary: SummaryText {
        let steps = validatedNonnegative(snapshot.dailyAggregate.steps)
        var details: [String] = []

        if let distance = formattedDistance(snapshot.dailyAggregate.distanceM) {
            details.append(distance)
        }
        if let activeEnergy = formattedDecimal(snapshot.dailyAggregate.activeEnergyKcal) {
            details.append("\(activeEnergy) kcal")
        }
        if let exercise = formattedDecimal(snapshot.dailyAggregate.exerciseMinutes) {
            details.append("\(exercise) 分钟")
        }

        guard steps != nil || !details.isEmpty else {
            return SummaryText(
                valueText: "暂无活动汇总",
                detailText: nil,
                accessibilityLabel: "当天活动汇总，暂无活动汇总"
            )
        }

        let value = steps.map { "\(formattedInteger($0)) 步" } ?? "活动数据已记录"
        let detail = details.isEmpty ? nil : details.joined(separator: " · ")
        return SummaryText(
            valueText: value,
            detailText: detail,
            accessibilityLabel: ["当天活动汇总", value, detail]
                .compactMap { $0 }
                .joined(separator: "，")
        )
    }

    var energySummary: SummaryText {
        switch snapshot.energyBalance.intake {
        case .noMeals:
            return unavailableEnergySummary("尚无餐次证据")
        case .incomplete:
            return unavailableEnergySummary("餐次热量不完整")
        case .complete:
            break
        }

        guard let burned = snapshot.energyBalance.burnedKcal,
              let intake = snapshot.energyBalance.intakeKcal,
              let burnedText = formattedDecimal(burned),
              let intakeText = formattedDecimal(intake)
        else {
            return unavailableEnergySummary("消耗数据不足")
        }

        guard let balance = snapshot.energyBalance.deficitKcal else {
            return unavailableEnergySummary("能量证据不足")
        }
        let value: String
        if balance >= 0, let balanceText = formattedDecimal(balance) {
            value = "缺口 \(balanceText) kcal"
        } else if let balanceText = formattedDecimal(-balance) {
            value = "盈余 \(balanceText) kcal"
        } else {
            return unavailableEnergySummary("能量证据不足")
        }
        let detail = "消耗 \(burnedText) kcal · 摄入 \(intakeText) kcal"
        return SummaryText(
            valueText: value,
            detailText: detail,
            accessibilityLabel: "当日能量证据，\(value)，\(detail)"
        )
    }

    var qualityText: String {
        let alertCount = snapshot.dataQuality.alerts.count
        if alertCount > 0 {
            return "\(alertCount) 项待确认"
        }
        return snapshot.dataQuality.wasReconciled ? "暂无待确认" : "尚未对账"
    }

    var qualityStyle: QualityPillStyle {
        if !snapshot.dataQuality.alerts.isEmpty {
            return .hasAlerts
        }
        return snapshot.dataQuality.wasReconciled ? .reconciledNoAlerts : .unreconciled
    }

    var timelineRows: [TimelineRow] {
        snapshot.timelineEntries.map { entry in
            switch entry {
            case let .meal(meal):
                return mealRow(entryID: entry.id, meal: meal)
            case let .medication(medication):
                return medicationRow(entryID: entry.id, medication: medication)
            }
        }
    }

    var timelineEmptyText: String {
        "今天还没有餐食或用药记录"
    }

    var sourceCoverageRows: [SourceCoverageRow] {
        snapshot.sourceCoverage.map { coverage in
            let title = sourceOriginTitle(coverage.origin)
            let sourceName = normalizedText(coverage.sourceName)
            let countText = coverage.sampleCount >= 0
                ? "\(coverage.sampleCount) 条样本"
                : "样本数未知"
            let detail = [sourceName, countText]
                .compactMap { $0 }
                .joined(separator: " · ")
            return SourceCoverageRow(
                id: "\(sourceOriginKey(coverage.origin))|\(sourceName ?? "")",
                title: title,
                detailText: detail,
                accessibilityLabel: "\(title)，\(detail)"
            )
        }
    }

    var sourceCoverageEmptyText: String {
        "当日暂无原始样本来源记录"
    }

    private func unavailableEnergySummary(_ value: String) -> SummaryText {
        SummaryText(
            valueText: value,
            detailText: nil,
            accessibilityLabel: "当日能量证据，\(value)"
        )
    }

    private func mealRow(
        entryID: String,
        meal: TodayMealEvidence
    ) -> TimelineRow {
        let title = mealKindTitle(meal.mealType)
        let time = timeText(meal.timelineAt)
        let calories: String
        if let value = formattedDecimal(meal.totals.caloriesKcal) {
            calories = "\(value) kcal"
        } else {
            calories = "热量未完整记录"
        }

        let macroValues: [(String, Double?)] = [
            ("P", meal.totals.proteinG),
            ("F", meal.totals.fatG),
            ("C", meal.totals.carbsG)
        ]
        let macros = macroValues.compactMap { label, value -> String? in
            guard let formatted = formattedDecimal(value) else { return nil }
            return "\(label) \(formatted) g"
        }
        let detail = macros.isEmpty ? nil : macros.joined(separator: " · ")

        let provenance: String
        if meal.provenanceKinds.isEmpty {
            provenance = "来源未记录"
        } else {
            provenance = "来源：" + meal.provenanceKinds
                .map(mealProvenanceTitle)
                .joined(separator: "、")
        }

        return TimelineRow(
            id: entryID,
            kind: .meal,
            timeText: time,
            title: title,
            primaryText: calories,
            detailText: detail,
            metadataText: provenance,
            accessibilityLabel: [title, "记录时间 \(time)", calories, detail, provenance]
                .compactMap { $0 }
                .joined(separator: "，")
        )
    }

    private func medicationRow(
        entryID: String,
        medication: TodayMedicationEvidence
    ) -> TimelineRow {
        let title = normalizedText(medication.planName) ?? "用药记录"
        let persistedAction = medicationActionText(
            medication.action,
            dosageMg: medication.dosageMg
        )

        let displayedTime: String
        let detail: String?
        let accessibilityTime: String
        if medication.timeBasis == .scheduledFallback {
            let scheduled = timeText(medication.timelineAt)
            displayedTime = "计划 \(scheduled)"
            detail = "动作时刻未记录"
            accessibilityTime = "计划时间 \(scheduled)"
        } else {
            let action = timeText(medication.timelineAt)
            displayedTime = action
            detail = nil
            accessibilityTime = "动作时间 \(action)"
        }

        return TimelineRow(
            id: entryID,
            kind: .medication,
            timeText: displayedTime,
            title: title,
            primaryText: persistedAction,
            detailText: detail,
            metadataText: nil,
            accessibilityLabel: [title, accessibilityTime, persistedAction, detail]
                .compactMap { $0 }
                .joined(separator: "，")
        )
    }

    private func medicationActionText(
        _ action: TodayMedicationAction,
        dosageMg: Double?
    ) -> String {
        switch action {
        case .taken:
            if let dosage = formattedDecimal(dosageMg) {
                return "已服用 \(dosage) mg"
            }
            return "已服用"
        case .skipped:
            return "已跳过"
        case .deferred:
            return "已延后"
        }
    }

    private func mealKindTitle(_ kind: TodayMealKind) -> String {
        switch kind {
        case .breakfast: return "早餐"
        case .lunch: return "午餐"
        case .dinner: return "晚餐"
        case .snack: return "加餐"
        }
    }

    private func mealProvenanceTitle(_ kind: TodayMealProvenanceKind) -> String {
        switch kind {
        case .manual: return "手动录入"
        case .aiEstimate: return "AI 估算"
        case .nutritionDatabase: return "营养数据库"
        case .nutritionLabel: return "营养标签"
        }
    }

    private func sourceOriginTitle(_ origin: TodaySourceOrigin) -> String {
        switch origin {
        case .garmin: return "Garmin"
        case .xiaomiMijia: return "米家 / 小米健康"
        case .xiaomiSports: return "小米运动 / Zepp"
        case .apple: return "Apple Health / Watch"
        case .hutool: return "华为 / 华米"
        case .manual: return "手动录入"
        case .unknown: return "未识别来源"
        }
    }

    private func sourceOriginKey(_ origin: TodaySourceOrigin) -> String {
        switch origin {
        case .garmin: return "garmin"
        case .xiaomiMijia: return "xiaomiMijia"
        case .xiaomiSports: return "xiaomiSports"
        case .apple: return "apple"
        case .hutool: return "hutool"
        case .manual: return "manual"
        case .unknown: return "unknown"
        }
    }

    private func formattedDistance(_ value: Double?) -> String? {
        guard let value = validatedNonnegative(value) else { return nil }
        if value >= 1_000 {
            guard let text = formattedDecimal(value / 1_000) else { return nil }
            return "\(text) km"
        }
        guard let text = formattedDecimal(value) else { return nil }
        return "\(text) m"
    }

    private func formattedInteger(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func formattedDecimal(_ value: Double?) -> String? {
        guard let value = validatedNonnegative(value) else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value))
    }

    private func validatedNonnegative(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private func validatedNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func normalizedText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private func dateFormatter(pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter
    }

    private func localizedDateFormatter(template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private func timeText(_ date: Date) -> String {
        dateFormatter(pattern: "HH:mm").string(from: date)
    }
}
