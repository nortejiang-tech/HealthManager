import XCTest
@testable import HealthManager

/// 饮食历史分页 / 搜索 / 日期筛选（验收 A14）：不漏、不重、后台可查。
final class MealHistoryQueryTests: XCTestCase {

    private func makeStore() -> MealStore {
        MealStore(databaseManager: DatabaseManager.makeInMemoryForTesting())
    }

    private func makeMeal(eatenAt: Int64, notes: String? = nil) -> MealRecord {
        MealRecord(
            id: nil,
            mealType: .lunch,
            eatenAt: eatenAt,
            caloriesKcal: nil,
            proteinG: nil,
            fatG: nil,
            carbsG: nil,
            photoPath: nil,
            notes: notes,
            createdAt: eatenAt,
            hkSyncId: nil
        )
    }

    private func insert(
        _ store: MealStore,
        eatenAt: Int64,
        notes: String? = nil,
        items: [String] = []
    ) async throws -> Int64 {
        let saved = try await store.save(
            meal: makeMeal(eatenAt: eatenAt, notes: notes),
            items: items.map { name in
                MealStore.ItemInput(
                    name: name,
                    grams: 100,
                    preparationState: .cooked,
                    caloriesKcal: 100,
                    proteinG: 10,
                    fatG: 5,
                    carbsG: 10,
                    provenanceKind: .manual
                )
            }
        )
        return saved.meal.id!
    }

    func test_historyPage_coversAllMealsWithoutGapsOrDuplicates() async throws {
        let store = makeStore()
        // 120 餐（超过旧版 50 条上限）。
        for index in 0..<120 {
            _ = try await insert(store, eatenAt: Int64(1_000_000 + index), notes: "meal-\(index)")
        }

        var seen = Set<Int64>()
        var offset = 0
        var pages = 0
        while true {
            let page = try await store.historyPage(
                limit: 50, offset: offset, searchText: nil, localDay: nil
            )
            if page.isEmpty { break }
            XCTAssertEqual(page.count, min(50, 120 - offset))
            for meal in page {
                XCTAssertTrue(seen.insert(meal.id!).inserted, "分页出现重复 id")
            }
            offset += page.count
            pages += 1
            if pages > 10 { return XCTFail("分页未收敛") }
        }
        XCTAssertEqual(seen.count, 120, "全部分页合计必须覆盖全部餐次")
        XCTAssertEqual(offset, 120)

        let total = try await store.historyTotalCount(searchText: nil, localDay: nil)
        XCTAssertEqual(total, 120)
    }

    func test_historyPage_searchMatchesNotesAndItemNames() async throws {
        let store = makeStore()
        _ = try await insert(store, eatenAt: 1_000, notes: "三个煮鸡蛋", items: [])
        _ = try await insert(store, eatenAt: 1_100, notes: nil, items: ["清炒油菜"])
        _ = try await insert(store, eatenAt: 1_200, notes: "公司午餐", items: ["干豆腐卷大葱"])
        _ = try await insert(store, eatenAt: 1_300, notes: "不相关", items: ["牛肉面"])

        let eggByNote = try await store.historyPage(limit: 50, offset: 0, searchText: "煮鸡蛋", localDay: nil)
        XCTAssertEqual(eggByNote.count, 1)

        let rapeByItem = try await store.historyPage(limit: 50, offset: 0, searchText: "油菜", localDay: nil)
        XCTAssertEqual(rapeByItem.count, 1, "分项名称也应可搜索")

        let tofu = try await store.historyPage(limit: 50, offset: 0, searchText: "干豆腐", localDay: nil)
        XCTAssertEqual(tofu.count, 1)

        let none = try await store.historyPage(limit: 50, offset: 0, searchText: "不存在的菜", localDay: nil)
        XCTAssertTrue(none.isEmpty)

        let total = try await store.historyTotalCount(searchText: "干豆腐", localDay: nil)
        XCTAssertEqual(total, 1)
    }

    func test_historyPage_filtersByLocalDay() async throws {
        let store = makeStore()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        _ = try await insert(store, eatenAt: Int64(today.timeIntervalSince1970) + 3600)
        _ = try await insert(store, eatenAt: Int64(today.timeIntervalSince1970) + 7200)
        _ = try await insert(store, eatenAt: Int64(yesterday.timeIntervalSince1970) + 3600)

        let todayMeals = try await store.historyPage(
            limit: 50, offset: 0, searchText: nil, localDay: today
        )
        XCTAssertEqual(todayMeals.count, 2)

        let yesterdayMeals = try await store.historyPage(
            limit: 50, offset: 0, searchText: nil, localDay: yesterday
        )
        XCTAssertEqual(yesterdayMeals.count, 1)
    }

    func test_historyPage_invalidOffsetReturnsEmpty_andSearchEscapesWildcards() async throws {
        let store = makeStore()
        _ = try await insert(store, eatenAt: 1_000, notes: "100%全麦", items: [])

        let outOfRange = try await store.historyPage(limit: 50, offset: 999, searchText: nil, localDay: nil)
        XCTAssertTrue(outOfRange.isEmpty)

        // % 作为字面量参与匹配，不变成通配符。
        let literal = try await store.historyPage(limit: 50, offset: 0, searchText: "100%全", localDay: nil)
        XCTAssertEqual(literal.count, 1)
        let wildcardAbuse = try await store.historyPage(limit: 50, offset: 0, searchText: "%%%", localDay: nil)
        XCTAssertTrue(wildcardAbuse.isEmpty)
    }
}
