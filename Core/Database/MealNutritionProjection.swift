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
        guard extracted.allSatisfy(isValidValue) else {
            return nil
        }
        return extracted.compactMap { $0 }.reduce(0, +)
    }

    private static func isValidValue(_ value: Double?) -> Bool {
        guard let value else { return false }
        return value.isFinite
    }
}
