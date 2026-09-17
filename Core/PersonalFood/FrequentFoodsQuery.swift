import Foundation
import GRDB

/// 常吃食物统计（§5.1）：
/// - 按 `meal_records.eaten_at` 的本地自然日窗口统计（默认近 30 个自然日，nil = 全部历史）；
/// - 每食物每餐只计一次（按 meal_id 去重）；
/// - 名称归并复用 MealItemIdentity.canonicalName（身份处理），语义等价归并只由
///   个人映射确认产生，这里不做模糊合并；
/// - 计数是「记录中出现的餐数」，不是准确的实际食用次数。
enum FrequentFoodsQuery {

    struct Summary: Equatable, Sendable {
        /// 规范名（候选键）。
        let key: String
        /// 展示名（最近一次使用的原始写法）。
        let displayName: String
        let mealCount: Int
        let lastEatenAt: Int64
        /// 记录中最常用克数（同频取更近使用；无克数记录为 nil）。
        let commonGrams: Double?
    }

    struct MealFacts: Equatable, Sendable {
        let mealId: Int64
        let eatenAt: Int64
        let items: [ItemFacts]

        struct ItemFacts: Equatable, Sendable {
            let name: String
            let grams: Double?
        }
    }

    /// 从数据库读取餐次分项事实。窗口为 nil 表示全部历史。
    static func loadMealFacts(
        db: Database,
        windowDays: Int?,
        calendar: Calendar = .current,
        now: Date = Date()
    ) throws -> [MealFacts] {
        var request = MealRecord.all()
            .order(Column("eaten_at").desc)
        if let windowDays {
            guard windowDays > 0 else { return [] }
            let dayStart = calendar.startOfDay(for: now)
            guard let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1), to: dayStart) else {
                return []
            }
            request = request.filter(Column("eaten_at") >= Int64(windowStart.timeIntervalSince1970))
        }
        let meals = try request.fetchAll(db)
        let mealIds = meals.compactMap(\.id)
        guard !mealIds.isEmpty else { return [] }

        let items = try MealItemRecord
            .filter(mealIds.contains(Column("meal_id")))
            .order(Column("meal_id"), Column("sort_order"))
            .fetchAll(db)
        let itemsByMeal = Dictionary(grouping: items, by: \.mealId)
        let eatenById = Dictionary(uniqueKeysWithValues: meals.compactMap { meal in
            meal.id.map { ($0, meal.eatenAt) }
        })

        return meals.compactMap { meal in
            guard let mealId = meal.id else { return nil }
            let facts = (itemsByMeal[mealId] ?? []).map {
                MealFacts.ItemFacts(name: $0.name, grams: $0.grams)
            }
            return MealFacts(
                mealId: mealId,
                eatenAt: eatenById[mealId] ?? meal.eatenAt,
                items: facts
            )
        }
    }

    /// 按规范名聚合出频次摘要。排序：餐数降序 → 最近食用降序 → key 稳定打破平局。
    static func summarize(mealFacts: [MealFacts]) -> [Summary] {
        struct Aggregate {
            var mealIds: Set<Int64> = []
            var lastEatenAt: Int64 = 0
            var displayName: String = ""
            var displayNameAt: Int64 = 0
            var grams: [Double: (count: Int, lastUsedAt: Int64)] = [:]
        }

        var aggregates: [String: Aggregate] = [:]
        for fact in mealFacts {
            var seenKeys = Set<String>()
            for item in fact.items {
                let key = MealItemIdentity.canonicalName(item.name)
                guard !key.isEmpty else { continue }
                // 同一餐内重复出现的同名食物只计一次（§5.1）。
                guard seenKeys.insert(key).inserted else { continue }

                var aggregate = aggregates[key] ?? Aggregate()
                aggregate.mealIds.insert(fact.mealId)
                if fact.eatenAt > aggregate.lastEatenAt {
                    aggregate.lastEatenAt = fact.eatenAt
                }
                if fact.eatenAt >= aggregate.displayNameAt {
                    aggregate.displayName = item.name
                    aggregate.displayNameAt = fact.eatenAt
                }
                if let grams = item.grams, grams > 0, grams.isFinite {
                    var entry = aggregate.grams[grams] ?? (count: 0, lastUsedAt: 0)
                    entry.count += 1
                    entry.lastUsedAt = max(entry.lastUsedAt, fact.eatenAt)
                    aggregate.grams[grams] = entry
                }
                aggregates[key] = aggregate
            }
        }

        return aggregates.map { key, aggregate in
            let commonGrams = aggregate.grams
                .max { lhs, rhs in
                    if lhs.value.count != rhs.value.count {
                        return lhs.value.count < rhs.value.count
                    }
                    if lhs.value.lastUsedAt != rhs.value.lastUsedAt {
                        return lhs.value.lastUsedAt < rhs.value.lastUsedAt
                    }
                    return lhs.key < rhs.key
                }?
                .key
            return Summary(
                key: key,
                displayName: aggregate.displayName,
                mealCount: aggregate.mealIds.count,
                lastEatenAt: aggregate.lastEatenAt,
                commonGrams: commonGrams
            )
        }
        .sorted {
            if $0.mealCount != $1.mealCount { return $0.mealCount > $1.mealCount }
            if $0.lastEatenAt != $1.lastEatenAt { return $0.lastEatenAt > $1.lastEatenAt }
            return $0.key < $1.key
        }
    }
}
