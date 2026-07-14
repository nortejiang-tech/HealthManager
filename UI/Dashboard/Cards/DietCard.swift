import SwiftUI
import Charts

struct DietCard: View {
    let data: DietCardData

    var body: some View {
        DashboardCard(
            theme: .diet, icon: "fork.knife", title: "今日饮食",
            accessory: {
                if data.hasIncompleteCalorieDays {
                    Text("近 7 日记录不完整")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    TrendChip(series: data.last7Days, theme: .diet)
                }
            }
        ) {
            CardMetric(
                value: data.todayCalories.map { String(format: "%.0f", $0) } ?? "—",
                unit: data.todayCalories == nil ? nil : "kcal",
                theme: .diet
            )

            if !data.meals.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(data.meals) { meal in
                        HStack {
                            Text(meal.mealType)
                                .frame(width: 36, alignment: .leading)
                            if let total = data.todayCalories, let kcal = meal.kcal {
                                ProgressView(value: kcal, total: max(total, 1))
                                    .progressViewStyle(.linear)
                                    .tint(CardTheme.diet.primary)
                            } else {
                                Spacer()
                            }
                            Text(meal.kcal.map { String(format: "%.0f", $0) } ?? "—")
                                .frame(width: 40, alignment: .trailing)
                                .monospacedDigit()
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
                if data.todayCalories == nil {
                    Text("存在未填写或无效热量的餐次")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                CardEmptyState(text: "今天还没记录")
            }

            if !data.meals.isEmpty {
                HStack(spacing: 10) {
                    macroPill(label: "P", value: data.todayProtein)
                    macroPill(label: "F", value: data.todayFat)
                    macroPill(label: "C", value: data.todayCarbs)
                }
            }
        }
    }

    private func macroPill(label: String, value: Double?) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 10).bold())
                .foregroundStyle(CardTheme.diet.primary)
            Text(value.map { String(format: "%.0fg", $0) } ?? "—")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(CardTheme.diet.primary.opacity(0.12), in: Capsule())
    }
}
