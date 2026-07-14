import Foundation

struct MealItemDraft: Identifiable, Equatable {
    enum ValidationError: LocalizedError, Equatable {
        case invalidGrams(String)

        var errorDescription: String? {
            switch self {
            case .invalidGrams(let raw):
                return "Invalid grams string: \(raw)"
            }
        }
    }

    let id: UUID = UUID()
    var name: String {
        didSet {
            markEditedIfNeeded(previous: oldValue, current: name)
        }
    }
    /// The raw grams string shown in the editor.
    var gramsText: String {
        didSet {
            markEditedIfNeeded(previous: oldValue, current: gramsText)
        }
    }
    /// Baseline source values used for proportional scaling.
    let baselineGrams: Double?
    let baselineCalories: Double?
    let baselineProtein: Double?
    let baselineFat: Double?
    let baselineCarbs: Double?

    let preparationState: MealItemRecord.PreparationState
    let provenanceKind: MealItemRecord.ProvenanceKind
    let provenanceRef: String?
    let provenanceVersion: String?
    let confidence: MealItemRecord.Confidence?

    private(set) var isUserEdited: Bool

    let createdAt: Int64?

    private init(
        name: String,
        gramsText: String,
        baselineGrams: Double? = nil,
        baselineCalories: Double? = nil,
        baselineProtein: Double? = nil,
        baselineFat: Double? = nil,
        baselineCarbs: Double? = nil,
        preparationState: MealItemRecord.PreparationState = .unknown,
        provenanceKind: MealItemRecord.ProvenanceKind = .manual,
        provenanceRef: String? = nil,
        provenanceVersion: String? = nil,
        confidence: MealItemRecord.Confidence? = nil,
        isUserEdited: Bool = false,
        createdAt: Int64? = nil
    ) {
        self.name = name
        self.gramsText = gramsText
        self.baselineGrams = baselineGrams
        self.baselineCalories = baselineCalories
        self.baselineProtein = baselineProtein
        self.baselineFat = baselineFat
        self.baselineCarbs = baselineCarbs
        self.preparationState = preparationState
        self.provenanceKind = provenanceKind
        self.provenanceRef = provenanceRef
        self.provenanceVersion = provenanceVersion
        self.confidence = confidence
        self.isUserEdited = isUserEdited
        self.createdAt = createdAt
    }

    init(itemInput: MealStore.ItemInput) {
        self.init(
            name: itemInput.name,
            gramsText: Self.displayText(from: itemInput.grams),
            baselineGrams: itemInput.grams,
            baselineCalories: itemInput.caloriesKcal,
            baselineProtein: itemInput.proteinG,
            baselineFat: itemInput.fatG,
            baselineCarbs: itemInput.carbsG,
            preparationState: itemInput.preparationState,
            provenanceKind: itemInput.provenanceKind,
            provenanceRef: itemInput.provenanceRef,
            provenanceVersion: itemInput.provenanceVersion,
            confidence: itemInput.confidence,
            isUserEdited: itemInput.isUserEdited,
            createdAt: nil
        )
    }

    static func manualEmpty() -> MealItemDraft {
        MealItemDraft(name: "", gramsText: "")
    }

    static func fromAiEstimate(
        item: MealNutritionAnalyzer.Item,
        batchConfidence: String?,
        modelName: String?,
        provenanceVersion: String? = nil
    ) -> MealItemDraft {
        let gramsText = Self.displayText(from: item.grams)
        return MealItemDraft(
            name: item.name,
            gramsText: gramsText,
            baselineGrams: item.grams,
            baselineCalories: item.calories_kcal,
            baselineProtein: item.protein_g,
            baselineFat: item.fat_g,
            baselineCarbs: item.carbs_g,
            provenanceKind: .aiEstimate,
            provenanceRef: Self.normalizedModelName(modelName),
            provenanceVersion: provenanceVersion,
            confidence: Self.normalizedConfidence(batchConfidence)
        )
    }

    init(record: MealItemRecord) {
        let gramsText = Self.displayText(from: record.grams)
        self.init(
            name: record.name,
            gramsText: gramsText,
            baselineGrams: record.grams,
            baselineCalories: record.caloriesKcal,
            baselineProtein: record.proteinG,
            baselineFat: record.fatG,
            baselineCarbs: record.carbsG,
            preparationState: record.preparationState,
            provenanceKind: record.provenanceKind,
            provenanceRef: record.provenanceRef,
            provenanceVersion: record.provenanceVersion,
            confidence: record.confidence,
            isUserEdited: record.isUserEdited,
            createdAt: record.createdAt
        )
    }

    static func normalizedConfidence(_ raw: String?) -> MealItemRecord.Confidence? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "low": return .low
        case "medium": return .medium
        case "high": return .high
        default: return nil
        }
    }

    static func normalizedModelName(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func toItemInput() throws -> MealStore.ItemInput {
        MealStore.ItemInput(
            name: name,
            grams: try validateGramsForStore(),
            preparationState: preparationState,
            caloriesKcal: calories,
            proteinG: protein,
            fatG: fat,
            carbsG: carbs,
            provenanceKind: provenanceKind,
            provenanceRef: provenanceRef,
            provenanceVersion: provenanceVersion,
            confidence: confidence,
            isUserEdited: isUserEdited,
            createdAt: createdAt
        )
    }

    var grams: Double? {
        guard let grams = Double(gramsText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        guard grams.isFinite, grams > 0 else { return nil }
        return grams
    }

    var calories: Double? {
        guard let baselineCalories else { return nil }
        return applyScale(to: baselineCalories)
    }

    var protein: Double? {
        guard let baselineProtein else { return nil }
        return applyScale(to: baselineProtein)
    }

    var fat: Double? {
        guard let baselineFat else { return nil }
        return applyScale(to: baselineFat)
    }

    var carbs: Double? {
        guard let baselineCarbs else { return nil }
        return applyScale(to: baselineCarbs)
    }

    var displayCalories: Double { calories ?? 0 }
    var displayProtein: Double { protein ?? 0 }
    var displayFat: Double { fat ?? 0 }
    var displayCarbs: Double { carbs ?? 0 }

    /// Conservative dedup key delegated to shared meal-item identity normalization.
    static func normalizedName(_ value: String) -> String {
        MealItemIdentity.canonicalName(value)
    }

    /// Filter `incoming` to names not already present in `existing`, including same-name
    /// repeats within the same batch.
    static func deduped(_ incoming: [MealItemDraft], against existing: [MealItemDraft]) -> [MealItemDraft] {
        var seen = Set(existing.map { normalizedName($0.name) })
        var out: [MealItemDraft] = []
        for item in incoming {
            let key = normalizedName(item.name)
            guard !key.isEmpty else { continue }
            if seen.insert(key).inserted { out.append(item) }
        }
        return out
    }

    private mutating func markEditedIfNeeded(previous: String, current: String) {
        guard provenanceKind != .manual else { return }
        guard !isUserEdited else { return }
        if previous != current {
            isUserEdited = true
        }
    }

    private func validateGramsForStore() throws -> Double? {
        let trimmed = gramsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Double(trimmed), value.isFinite, value > 0 else {
            throw ValidationError.invalidGrams(trimmed)
        }
        return value
    }

    private func applyScale(to baselineValue: Double) -> Double {
        guard let baselineGrams = baselineGrams, baselineGrams.isFinite, baselineGrams > 0 else {
            return baselineValue
        }
        guard let enteredGrams = grams else {
            return baselineValue
        }
        return baselineValue * enteredGrams / baselineGrams
    }

    private static func displayText(from value: Double?) -> String {
        guard let value else { return "" }
        if value == value.rounded() { return String(format: "%.0f", value) }
        return String(value)
    }
}
