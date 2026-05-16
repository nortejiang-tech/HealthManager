import SwiftUI
import GRDB

struct ManualActivityEntryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var kind: ManualActivityKind = .soccer
    @State private var startAt = Date()
    @State private var durationMinutes = ""
    @State private var distanceKm = ""
    @State private var latestWeightKg: Double?
    @State private var isSaving = false
    @State private var errorText: String?

    private let fallbackWeightKg: Double = 75

    var body: some View {
        NavigationStack {
            Form {
                Section("活动") {
                    Picker("类型", selection: $kind) {
                        ForEach(ManualActivityKind.allCases) { item in
                            Label(item.displayName, systemImage: item.systemImage)
                                .tag(item)
                        }
                    }
                    DatePicker("开始时间", selection: $startAt, displayedComponents: [.date, .hourAndMinute])
                    LabeledTextField(label: "时长（分钟）", text: $durationMinutes, keyboard: .decimalPad)
                    LabeledTextField(label: "距离（公里，可选）", text: $distanceKm, keyboard: .decimalPad)
                }

                Section {
                    LabeledContent("体重", value: String(format: "%.1f kg", estimateWeight))
                    LabeledContent("强度", value: String(format: "%.1f MET", kind.met))
                    LabeledContent("估算时长", value: estimatedMinutes.map { String(format: "%.0f 分钟", $0) } ?? "—")
                    LabeledContent("活动消耗", value: estimatedCalories.map { String(format: "%.0f kcal", $0) } ?? "—")
                } header: {
                    Text("估算")
                } footer: {
                    Text(weightFooter)
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("补录活动")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task { await save() }
                    }
                    .disabled(isSaving || estimatedCalories == nil)
                }
            }
            .task { await loadLatestWeight() }
        }
    }

    private var estimateWeight: Double {
        latestWeightKg ?? fallbackWeightKg
    }

    private var weightFooter: String {
        if latestWeightKg == nil {
            return "没有找到最近体重，暂按 75 kg 估算。补录体重后，新活动会按最新体重计算。"
        }
        return "估算公式：MET × 体重 × 小时。距离只在没有填写时长时用于反推时长。"
    }

    private var enteredDurationMinutes: Double? {
        positiveDouble(durationMinutes)
    }

    private var enteredDistanceKm: Double? {
        positiveDouble(distanceKm)
    }

    private var estimatedMinutes: Double? {
        if let enteredDurationMinutes {
            return enteredDurationMinutes
        }
        if let enteredDistanceKm {
            return (enteredDistanceKm / kind.defaultSpeedKmH) * 60
        }
        return nil
    }

    private var estimatedCalories: Double? {
        guard let estimatedMinutes, estimatedMinutes > 0 else { return nil }
        return kind.met * estimateWeight * (estimatedMinutes / 60)
    }

    private func positiveDouble(_ text: String) -> Double? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else { return nil }
        return value
    }

    private func loadLatestWeight() async {
        do {
            let weight = try await environment.database.asyncRead { db in
                try Double.fetchOne(db, sql: """
                    SELECT weight_kg
                    FROM body_metrics_daily
                    WHERE weight_kg IS NOT NULL
                    ORDER BY date DESC
                    LIMIT 1
                    """)
            }
            await MainActor.run { latestWeightKg = weight }
        } catch {
            AppLogger.shared.error("Manual activity weight lookup failed: \(error.localizedDescription)")
        }
    }

    private func save() async {
        guard let minutes = estimatedMinutes,
              let calories = estimatedCalories
        else { return }

        await MainActor.run {
            isSaving = true
            errorText = nil
        }

        do {
            let durationSeconds = Int64((minutes * 60).rounded())
            let startEpoch = Int64(startAt.timeIntervalSince1970)
            let endEpoch = startEpoch + max(60, durationSeconds)
            let sourceBundle = Bundle.main.bundleIdentifier ?? "com.norte.HealthManager"
            let extra = try extraJson(
                durationSeconds: Double(max(60, durationSeconds)),
                calories: calories,
                distanceMeters: enteredDistanceKm.map { $0 * 1000 },
                estimatedFrom: enteredDurationMinutes == nil ? "distance" : "duration"
            )

            try await environment.database.asyncWrite { db in
                try db.execute(sql: """
                    INSERT INTO health_samples_raw
                      (sample_uuid, hk_type, kind, value, unit, start_at, end_at,
                       source_name, source_bundle_id, ingested_at, is_deleted, extra_json, source_origin)
                    VALUES (?, ?, 'workout', ?, 'second', ?, ?, ?, ?, ?, 0, ?, ?)
                    """, arguments: [
                        "manual-\(UUID().uuidString)",
                        ActivityEnergyCalculator.workoutType,
                        Double(max(60, durationSeconds)),
                        startEpoch,
                        endEpoch,
                        "健康管理",
                        sourceBundle,
                        Int64(Date().timeIntervalSince1970),
                        extra,
                        SourceAttribution.Origin.manual.rawValue
                    ])
            }

            await environment.syncEngine.runCatchUpAggregation(windowDays: 7)
            environment.notifyLocalDataChanged()
            await MainActor.run {
                isSaving = false
                dismiss()
            }
        } catch {
            await MainActor.run {
                isSaving = false
                errorText = "保存失败：\(error.localizedDescription)"
            }
            AppLogger.shared.error("Manual activity save failed: \(error.localizedDescription)")
        }
    }

    private func extraJson(
        durationSeconds: Double,
        calories: Double,
        distanceMeters: Double?,
        estimatedFrom: String
    ) throws -> String {
        var dict: [String: Any] = [
            "activityType": kind.workoutActivityTypeRaw,
            "duration": durationSeconds,
            "manualActivityKind": kind.rawValue,
            "manualActivityName": kind.displayName,
            "totalEnergyKcal": calories,
            "estimatedFrom": estimatedFrom,
            "met": kind.met,
            "weightKg": estimateWeight
        ]
        if let distanceMeters {
            dict["totalDistanceMeters"] = distanceMeters
        }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
