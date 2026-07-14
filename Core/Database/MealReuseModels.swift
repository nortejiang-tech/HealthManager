import Foundation

enum MealItemIdentity {
    static func canonicalName(_ value: String) -> String {
        String(
            value.unicodeScalars
                .filter { !$0.properties.isWhitespace }
                .map { Character($0) }
        )
        .lowercased()
    }
}

extension MealStore {
    enum CopySelection: Equatable, Sendable {
        case wholeMeal
        case itemIds(Set<Int64>)
    }

    struct CommonGramSuggestion: Equatable, Sendable {
        let grams: Double
        let useCount: Int
        let lastUsedAt: Int64
    }

    struct CopyDraft: Equatable, Sendable {
        let meal: MealRecord
        let items: [ItemInput]
    }

    enum ReuseError: Error, Equatable {
        case emptySelection
        case missingItemIds([Int64])
    }
}
