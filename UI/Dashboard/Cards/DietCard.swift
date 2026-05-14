import SwiftUI
import Charts

struct DietCard: View {
    let data: DietCardData

    var body: some View {
        DashboardCard(theme: .diet, icon: "fork.knife", title: "今日饮食") {
            CardMetric(
                value: data.todayCalories > 0 ? String(format: "%.0f", data.todayCalories) : "—",
                unit: data.todayCalories > 0 ? "kcal" : nil,
                theme: .diet
            )

            if !data.meals.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(data.meals) { meal in
                        HStack {
                            Text(meal.mealType)
                                .frame(width: 36, alignment: .leading)
                            ProgressView(value: meal.kcal, total: max(data.todayCalories, 1))
                                .progressViewStyle(.linear)
                                .tint(CardTheme.diet.primary)
                            Text(String(format: "%.0f", meal.kcal))
                                .frame(width: 40, alignment: .trailing)
                                .monospacedDigit()
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                CardEmptyState(text: "今天还没记录")
            }

            if data.todayProtein + data.todayFat + data.todayCarbs > 0 {
                HStack(spacing: 10) {
                    macroPill(label: "P", value: data.todayProtein)
                    macroPill(label: "F", value: data.todayFat)
                    macroPill(label: "C", value: data.todayCarbs)
                }
            }
        }
    }

    private func macroPill(label: String, value: Double) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 10).bold())
                .foregroundStyle(CardTheme.diet.primary)
            Text(String(format: "%.0fg", value))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(CardTheme.diet.primary.opacity(0.12), in: Capsule())
    }
}
