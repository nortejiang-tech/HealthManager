import SwiftUI

/// 「我的常吃」段（§4.3）：已匹配的常吃单品 / 我的配方与固定餐 / 待确认候选，
/// 三种条目同页分区展示，不增加独立页面。
/// 频次统计实时重建；候选确认/忽略是用户数据，随备份 v2 持久化。
struct MyFrequentPanel: View {
    enum WindowOption: String, CaseIterable, Identifiable {
        case recent
        case all

        var id: String { rawValue }
        var windowDays: Int? {
            self == .recent ? 30 : nil
        }
        var title: String {
            self == .recent ? "近 30 天" : "全部历史"
        }
    }

    @EnvironmentObject private var environment: AppEnvironment

    let catalogStore: FoodCatalogStore
    /// 外部触发刷新（例如候选确认/配方保存后）。
    let refreshToken: Int
    let onAddToMeal: ([MealItemDraft]) -> Void
    let onMatchCandidate: (FrequentFoodsQuery.Summary) -> Void
    let onEditRecipe: (PersonalFoodStore.RecipeWithVersion) -> Void
    let onCreateRecipe: (FrequentFoodsQuery.Summary) -> Void
    /// 「生成参考配方」：由父级编排推测（可能耗时/需模型），失败时父级回退手动。
    var onGenerateRecipe: ((FrequentFoodsQuery.Summary) -> Void)? = nil

    @State private var page: PersonalFoodStore.FrequentPage?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var window: WindowOption = .recent
    @State private var actionErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("统计窗口", selection: $window) {
                ForEach(WindowOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("nutrition-frequent-window")

            if let loadError {
                HMInlineRecovery(
                    title: "常吃统计读取失败",
                    message: "已保存的记录不受影响；可以重试读取。",
                    technicalDetails: loadError,
                    actionTitle: "重试",
                    onAction: {
                        Task { await load() }
                    }
                )
            } else if isLoading, page == nil {
                VStack(spacing: 10) {
                    HMLoadingSkeleton(height: 44)
                    HMLoadingSkeleton(height: 44)
                    HMLoadingSkeleton(height: 44)
                }
            } else if let page {
                sections(page)
            }
        }
        .task(id: "\(window.rawValue)-\(refreshToken)") {
            await load()
        }
        .alert("操作失败", isPresented: .init(
            get: { actionErrorMessage != nil },
            set: { if !$0 { actionErrorMessage = nil } }
        )) {
            Button("确定", role: .cancel) { actionErrorMessage = nil }
        } message: {
            Text(actionErrorMessage ?? "")
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await environment.personalFoodStore.loadFrequentPage(windowDays: window.windowDays)
            await MainActor.run { page = loaded }
        } catch {
            await MainActor.run { loadError = error.localizedDescription }
            AppLogger.shared.error("Frequent foods load failed: \(error.localizedDescription)")
        }
    }

    @ViewBuilder
    private func sections(_ page: PersonalFoodStore.FrequentPage) -> some View {
        let hasNothing = page.matchedFoods.isEmpty && page.recipes.isEmpty && page.pendingCandidates.isEmpty
        if hasNothing {
            HMEmptyState(
                title: window == .recent ? "近 30 天还没有常吃记录" : "还没有可整理的记录",
                message: "保存餐次后，这里会自动整理你常吃的食物与组合，供一键复用。",
                icon: "fork.knife.circle",
                tone: .neutral,
                primaryActionTitle: nil,
                secondaryActionTitle: nil
            )
        } else {
            if !page.matchedFoods.isEmpty {
                sectionHeader("已匹配的常吃")
                foodRows(page.matchedFoods)
            }
            if !page.recipes.isEmpty {
                sectionHeader("我的配方 / 固定餐")
                recipeRows(page.recipes)
            }
            if !page.pendingCandidates.isEmpty {
                sectionHeader("待确认候选")
                Text("以下来自你的真实记录；确认一次后即可长期复用，被忽略的不再出现。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                candidateRows(page.pendingCandidates)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .padding(.top, 4)
    }

    // MARK: 已匹配单品

    private func foodRows(_ foods: [PersonalFoodStore.MatchedFood]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(foods.enumerated()), id: \.element.food.id) { index, matched in
                matchedFoodRow(matched)
                if index < foods.count - 1 {
                    Divider().overlay(HMColors.separator).padding(.leading, 14)
                }
            }
        }
        .background(HMColors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(HMColors.separator, lineWidth: 1))
    }

    private func matchedFoodRow(_ matched: PersonalFoodStore.MatchedFood) -> some View {
        let food = matched.food
        let entry = food.catalogEntryId.flatMap { catalogStore.entry(id: $0) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if food.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(HMColors.comparison)
                        .accessibilityLabel("已置顶")
                }
                Text(food.displayName)
                    .font(.body.weight(.medium))
                Spacer(minLength: 8)
                if let entry {
                    Text("\(NutritionFormatting.kcal(entry.nutrients.kcal)) kcal/100g")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("目录条目缺失")
                        .font(.caption2)
                        .foregroundStyle(HMColors.actionRequired)
                }
            }
            Text("近30天记录 \(matched.recentMealCount) 餐 · 官方参考")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if entry != nil {
                    Button {
                        addToMeal(matched: matched, entry: entry)
                    } label: {
                        Label("加入饮食", systemImage: "plus.circle.fill")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(HMColors.primaryAction)
                    .accessibilityIdentifier("nutrition-frequent-add-\(food.id ?? -1)")
                }
                Button {
                    togglePin(matched)
                } label: {
                    Label(food.pinned ? "取消置顶" : "置顶", systemImage: food.pinned ? "pin.slash" : "pin")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addToMeal(matched: PersonalFoodStore.MatchedFood, entry: FoodCatalogEntry?) {
        guard let entry else {
            let entryId = matched.food.catalogEntryId ?? "未知"
            actionErrorMessage = "目录中找不到该条目（\(entryId)），无法生成官方参考草稿。"
            return
        }
        let grams = matched.food.defaultGrams ?? matched.recentCommonGrams
        let draft = MealItemDraft.fromMatchedFood(
            matched.food,
            entry: entry,
            catalogVersion: matched.food.catalogVersion ?? catalogStore.catalog.source.edition,
            grams: grams
        )
        onAddToMeal([draft])
    }

    private func togglePin(_ matched: PersonalFoodStore.MatchedFood) {
        guard let id = matched.food.id else { return }
        Task {
            do {
                try await environment.personalFoodStore.setPinned(foodId: id, pinned: !matched.food.pinned)
                await load()
            } catch {
                await MainActor.run { actionErrorMessage = error.localizedDescription }
            }
        }
    }

    // MARK: 配方 / 固定餐

    private func recipeRows(_ recipes: [PersonalFoodStore.RecipeWithVersion]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(recipes.enumerated()), id: \.element.recipe.id) { index, item in
                recipeRow(item)
                if index < recipes.count - 1 {
                    Divider().overlay(HMColors.separator).padding(.leading, 14)
                }
            }
        }
        .background(HMColors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(HMColors.separator, lineWidth: 1))
    }

    private func recipeRow(_ item: PersonalFoodStore.RecipeWithVersion) -> some View {
        // 快照优先；无快照且目录解析失败、或待匹配原料一律按未知贡献，
        // 不得跳过后仍显示完整总量（ADR-005：漏算路径修复）。
        let unknownNutrients = FoodCatalogEntry.Nutrients(
            kcal: FoodCatalogNutrient(value: nil, flag: .unmeasured),
            proteinG: FoodCatalogNutrient(value: nil, flag: .unmeasured),
            fatG: FoodCatalogNutrient(value: nil, flag: .unmeasured),
            carbsG: FoodCatalogNutrient(value: nil, flag: .unmeasured),
            fiberG: FoodCatalogNutrient(value: nil, flag: .unmeasured),
            sodiumMg: FoodCatalogNutrient(value: nil, flag: .unmeasured)
        )
        let calculation = RecipeCalculator.calculate(
            ingredients: item.version.ingredients.map { ingredient -> RecipeCalculator.IngredientInput in
                if ingredient.isPendingMatch {
                    return RecipeCalculator.IngredientInput(
                        per100: unknownNutrients,
                        grams: ingredient.grams,
                        status: ingredient.amountStatus == .notUsed ? .notUsed : .unknown
                    )
                }
                if let snapshot = ingredient.nutritionSnapshot {
                    return RecipeCalculator.IngredientInput(
                        per100: snapshot.per100,
                        grams: ingredient.grams,
                        status: ingredient.amountStatus
                    )
                }
                guard let entry = catalogStore.entry(id: ingredient.catalogEntryId) else {
                    return RecipeCalculator.IngredientInput(
                        per100: unknownNutrients,
                        grams: ingredient.grams,
                        status: ingredient.amountStatus == .notUsed ? .notUsed : .unknown
                    )
                }
                return RecipeCalculator.IngredientInput(
                    per100: entry.nutrients,
                    grams: ingredient.grams,
                    status: ingredient.amountStatus
                )
            },
            outputGrams: item.version.outputGrams
        )
        let pendingCount = item.version.ingredients.filter(\.isPendingMatch).count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.recipe.displayName)
                    .font(.body.weight(.medium))
                Text("v\(item.version.version)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer(minLength: 8)
                if let kcal = calculation.totals.caloriesKcal {
                    Text("每份 \(String(format: "%.0f", kcal)) kcal")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("营养待补")
                        .font(.caption2)
                        .foregroundStyle(HMColors.actionRequired)
                }
            }
            HStack(spacing: 8) {
                Text("近30天记录 \(item.recentMealCount) 餐 · 我的配方估算")
                if item.version.outputGrams == nil {
                    Text("待补成品重量")
                }
                if pendingCount > 0 {
                    Text("待匹配原料 ×\(pendingCount)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    let entries = Dictionary(
                        uniqueKeysWithValues: item.version.ingredients.compactMap { ingredient in
                            catalogStore.entry(id: ingredient.catalogEntryId).map { ($0.id, $0) }
                        }
                    )
                    let draft = MealItemDraft.fromRecipe(
                        recipe: item.recipe,
                        version: item.version,
                        entries: entries,
                        grams: item.version.outputGrams
                    )
                    onAddToMeal([draft])
                } label: {
                    Label("加入饮食", systemImage: "plus.circle.fill")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(HMColors.primaryAction)

                Button {
                    onEditRecipe(item)
                } label: {
                    Label("编辑配方", systemImage: "slider.horizontal.3")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 待确认候选

    private func candidateRows(_ candidates: [FrequentFoodsQuery.Summary]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(candidates.enumerated()), id: \.element.key) { index, candidate in
                candidateRow(candidate)
                if index < candidates.count - 1 {
                    Divider().overlay(HMColors.separator).padding(.leading, 14)
                }
            }
        }
        .background(HMColors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(HMColors.separator, lineWidth: 1))
    }

    private func candidateRow(_ candidate: FrequentFoodsQuery.Summary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(candidate.displayName)
                    .font(.body.weight(.medium))
                Spacer(minLength: 8)
                Text("近30天记录 \(candidate.mealCount) 餐")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("待确认食材/做法——没有可靠的官方数值，不显示猜测值")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    onMatchCandidate(candidate)
                } label: {
                    Label("匹配官方条目", systemImage: "book")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("nutrition-candidate-match-\(candidate.key)")

                if let onGenerateRecipe {
                    Button {
                        onGenerateRecipe(candidate)
                    } label: {
                        Label("生成参考配方", systemImage: "wand.and.stars")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(HMColors.estimate)
                    .accessibilityIdentifier("nutrition-candidate-generate-\(candidate.key)")
                } else {
                    Button {
                        onCreateRecipe(candidate)
                    } label: {
                        Label("手动建配方", systemImage: "slider.horizontal.3")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                }

                Button(role: .destructive) {
                    Task { await ignore(candidate) }
                } label: {
                    Label("忽略", systemImage: "eye.slash")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ignore(_ candidate: FrequentFoodsQuery.Summary) async {
        do {
            try await environment.personalFoodStore.ignoreCandidate(key: candidate.key)
            await load()
        } catch {
            await MainActor.run { actionErrorMessage = error.localizedDescription }
        }
    }
}
