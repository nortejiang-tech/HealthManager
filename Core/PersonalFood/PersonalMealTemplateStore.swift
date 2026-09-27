import Foundation
import GRDB

/// Stores user-confirmed meal-item snapshots independently from eaten meals and recipes.
final class PersonalMealTemplateStore: @unchecked Sendable {

    enum StoreError: Error, Equatable, LocalizedError {
        case invalidInput(String)
        case templateNotFound(Int64)
        case corruptTemplate(Int64)

        var errorDescription: String? {
            switch self {
            case .invalidInput(let detail): return "固定菜品输入无效：\(detail)"
            case .templateNotFound(let id): return "固定菜品不存在（\(id)）"
            case .corruptTemplate(let id): return "固定菜品数据无法解析（\(id)）"
            }
        }
    }

    struct Template: Equatable, Sendable, Identifiable {
        let id: Int64
        let displayName: String
        let items: [PersonalMealTemplateItem]
        let createdAt: Int64
        let updatedAt: Int64
    }

    private let databaseManager: DatabaseManager
    private let now: @Sendable () -> Int64

    init(
        databaseManager: DatabaseManager,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.databaseManager = databaseManager
        self.now = now
    }

    func loadAll() async throws -> [Template] {
        try await databaseManager.asyncRead { db in
            try PersonalMealTemplateRecord
                .order(Column("updated_at").desc, Column("id").desc)
                .fetchAll(db)
                .map(Self.decode)
        }
    }

    func save(
        id: Int64?,
        name: String,
        items: [MealStore.ItemInput]
    ) async throws -> Template {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw StoreError.invalidInput("菜品名称不能为空") }
        guard !items.isEmpty else { throw StoreError.invalidInput("至少需要一个菜品分项") }

        let snapshots = items.map(PersonalMealTemplateItem.init(item:))
        guard snapshots.allSatisfy(Self.isValid) else {
            throw StoreError.invalidInput("分项名称、克数或营养值无效")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let itemsJSON = String(decoding: try encoder.encode(snapshots), as: UTF8.self)

        return try await databaseManager.asyncWrite { [now = self.now] db in
            let timestamp = now()
            var record: PersonalMealTemplateRecord
            if let id {
                guard let existing = try PersonalMealTemplateRecord.fetchOne(db, key: id) else {
                    throw StoreError.templateNotFound(id)
                }
                record = existing
                record.displayName = trimmedName
                record.itemsJSON = itemsJSON
                record.updatedAt = timestamp
                try record.update(db)
            } else {
                record = PersonalMealTemplateRecord(
                    id: nil,
                    displayName: trimmedName,
                    itemsJSON: itemsJSON,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
                try record.insert(db)
            }
            return try Self.decode(record)
        }
    }

    func delete(id: Int64) async throws {
        try await databaseManager.asyncWrite { db in
            guard try PersonalMealTemplateRecord.deleteOne(db, key: id) else {
                throw StoreError.templateNotFound(id)
            }
        }
    }

    private static func decode(_ record: PersonalMealTemplateRecord) throws -> Template {
        guard let id = record.id,
              let data = record.itemsJSON.data(using: .utf8),
              let items = try? JSONDecoder().decode([PersonalMealTemplateItem].self, from: data) else {
            throw StoreError.corruptTemplate(record.id ?? -1)
        }
        return Template(
            id: id,
            displayName: record.displayName,
            items: items,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }

    private static func isValid(_ item: PersonalMealTemplateItem) -> Bool {
        guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let grams = item.grams, (!grams.isFinite || grams <= 0) { return false }
        return [item.caloriesKcal, item.proteinG, item.fatG, item.carbsG].allSatisfy { value in
            guard let value else { return true }
            return value.isFinite && value >= 0
        }
    }
}
