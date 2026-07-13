import XCTest

@testable import HealthManager

final class MealNutritionProjectionTests: XCTestCase {

    func test_projectReturnsNilWhenNoValues() {
        XCTAssertNil(MealNutritionProjection.project([]))
    }

    func test_projectSumsAllKnownValues() {
        let totals = MealNutritionProjection.project([
            MealNutritionValues(caloriesKcal: 10, proteinG: 2, fatG: 1, carbsG: 3),
            MealNutritionValues(caloriesKcal: 5, proteinG: 1, fatG: 4, carbsG: 2)
        ])

        XCTAssertEqual(totals?.caloriesKcal, 15)
        XCTAssertEqual(totals?.proteinG, 3)
        XCTAssertEqual(totals?.fatG, 5)
        XCTAssertEqual(totals?.carbsG, 5)
    }

    func test_projectSumsIndicatorsIndependentlyWithNilInvalidation() {
        let totals = MealNutritionProjection.project([
            MealNutritionValues(
                caloriesKcal: 100,
                proteinG: 10,
                fatG: 5,
                carbsG: nil
            ),
            MealNutritionValues(
                caloriesKcal: 20,
                proteinG: nil,
                fatG: 3,
                carbsG: 11
            )
        ])

        XCTAssertNotNil(totals)
        XCTAssertEqual(totals?.caloriesKcal, 120)
        XCTAssertNil(totals?.proteinG)
        XCTAssertEqual(totals?.fatG, 8)
        XCTAssertNil(totals?.carbsG)
    }

    func test_projectSingleMetricUnknownLeavesOthersIntact() {
        let totals = MealNutritionProjection.project([
            MealNutritionValues(
                caloriesKcal: 8,
                proteinG: 1,
                fatG: 2,
                carbsG: 3
            ),
            MealNutritionValues(
                caloriesKcal: 12,
                proteinG: Double.infinity,
                fatG: 4,
                carbsG: 5
            )
        ])

        XCTAssertNil(totals?.proteinG)
        XCTAssertEqual(totals?.caloriesKcal, 20)
        XCTAssertEqual(totals?.fatG, 6)
        XCTAssertEqual(totals?.carbsG, 8)
    }

    func test_projectReturnsNilForInvalidNumericMetric() {
        let totals = MealNutritionProjection.project([
            MealNutritionValues(
                caloriesKcal: 10,
                proteinG: 1,
                fatG: 2,
                carbsG: 3
            ),
            MealNutritionValues(
                caloriesKcal: 5,
                proteinG: Double.nan,
                fatG: 4,
                carbsG: 6
            )
        ])

        XCTAssertNotNil(totals)
        XCTAssertEqual(totals?.caloriesKcal, 15)
        XCTAssertNil(totals?.proteinG)
        XCTAssertEqual(totals?.fatG, 6)
        XCTAssertEqual(totals?.carbsG, 9)
    }

    func test_projectReturnsNilMetricWhenAllUnknownInOneMetric() {
        let totals = MealNutritionProjection.project([
            MealNutritionValues(caloriesKcal: nil, proteinG: nil, fatG: nil, carbsG: 1),
            MealNutritionValues(caloriesKcal: nil, proteinG: nil, fatG: nil, carbsG: 3)
        ])

        XCTAssertNil(totals?.caloriesKcal)
        XCTAssertNil(totals?.proteinG)
        XCTAssertNil(totals?.fatG)
        XCTAssertEqual(totals?.carbsG, 4)
    }

    func test_projectAllowsKnownZero() {
        let totals = MealNutritionProjection.project([
            MealNutritionValues(caloriesKcal: 0, proteinG: 0, fatG: 0, carbsG: 0),
            MealNutritionValues(caloriesKcal: 1, proteinG: 2, fatG: 0, carbsG: 3)
        ])

        XCTAssertEqual(totals?.caloriesKcal, 1)
        XCTAssertEqual(totals?.proteinG, 2)
        XCTAssertEqual(totals?.fatG, 0)
        XCTAssertEqual(totals?.carbsG, 3)
    }

    func test_totalsHasWritableValueRequiresFinitePositiveMetric() {
        let noWritable = MealNutritionTotals(
            caloriesKcal: 0,
            proteinG: 0,
            fatG: nil,
            carbsG: -1
        )
        XCTAssertFalse(noWritable.hasWritableValue)

        let writable = MealNutritionTotals(
            caloriesKcal: nil,
            proteinG: 12,
            fatG: 0,
            carbsG: nil
        )
        XCTAssertTrue(writable.hasWritableValue)

        let nonFinite = MealNutritionTotals(caloriesKcal: nil, proteinG: Double.nan, fatG: 0, carbsG: nil)
        XCTAssertFalse(nonFinite.hasWritableValue)
    }
}
