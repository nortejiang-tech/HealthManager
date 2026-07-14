import Foundation

struct MealNutritionValues: Equatable, Sendable {
    let caloriesKcal: Double?
    let proteinG: Double?
    let fatG: Double?
    let carbsG: Double?

    init(caloriesKcal: Double?, proteinG: Double?, fatG: Double?, carbsG: Double?) {
        self.caloriesKcal = caloriesKcal
        self.proteinG = proteinG
        self.fatG = fatG
        self.carbsG = carbsG
    }
}

struct MealNutritionTotals: Equatable, Sendable {
    let caloriesKcal: Double?
    let proteinG: Double?
    let fatG: Double?
    let carbsG: Double?

    var hasWritableValue: Bool {
        [caloriesKcal, proteinG, fatG, carbsG].contains {
            guard let value = $0 else { return false }
            return value > 0 && value.isFinite
        }
    }
}

enum MealNutritionProjection {
    static func validatedValue(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func project(_ values: [MealNutritionValues]) -> MealNutritionTotals? {
        guard !values.isEmpty else { return nil }

        return MealNutritionTotals(
            caloriesKcal: aggregate(values, \.caloriesKcal),
            proteinG: aggregate(values, \.proteinG),
            fatG: aggregate(values, \.fatG),
            carbsG: aggregate(values, \.carbsG)
        )
    }

    private static func aggregate(
        _ values: [MealNutritionValues],
        _ keyPath: KeyPath<MealNutritionValues, Double?>
    ) -> Double? {
        let extracted = values.map { $0[keyPath: keyPath] }
        guard extracted.allSatisfy({ validatedValue($0) != nil }) else {
            return nil
        }
        let total = extracted.compactMap { $0 }.reduce(0, +)
        return total.isFinite ? total : nil
    }
}
