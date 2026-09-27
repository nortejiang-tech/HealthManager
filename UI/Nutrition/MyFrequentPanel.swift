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
    let onCreateTemplate: (String, [MealItemDraft]) -> Void
    let onEditTemplate: (PersonalMealTemplateStore.Template) -> Void
    /// 「生成参考配方」：由父级编排推测（可能耗时/需模型），失败时父级回退手动。
    var onGenerateRecipe: ((FrequentFoodsQuery.Summary) -> Void)? = nil

    @State private var page: PersonalFoodStore.FrequentPage?
    @State private var templates: [PersonalMealTemplateStore.Template] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var templatesLoadError: String?
    @State private var window: WindowOption = .recent
    @State private var actionErrorMessage: String?
    @State private var templateToDelete: PersonalMealTemplateStore.Template?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("统计窗口", selection: $window) {
                ForEach(WindowOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("nutrition-frequent-window")

            Button {
                onCreateTemplate("", [])
            } label: {
                Label("添加固定菜品", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity, minHeight: 42)
            }
            .buttonStyle(.bordered)
            .tint(HMColors.primaryAction)
            .accessibilityIdentifier("nutrition-template-create")

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
        .confirmationDialog(
            "删除固定菜品？",
            isPresented: Binding(
                get: { templateToDelete != nil },
                set: { if !$0 { templateToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard let template = templateToDelete else { return }
                templateToDelete = nil
                Task { await deleteTemplate(template) }
            }
            Button("取消", role: .cancel) { templateToDelete = nil }
        } message: {
            Text(templateToDelete?.displayName ?? "")
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await environment.personalFoodStore.loadFrequentPage(windowDays: window.windowDays)
            await MainActor.run { page = loaded }
            do {
                let loadedTemplates = try await environment.personalMealTemplateStore.loadAll()
                await MainActor.run {
                    templates = loadedTemplates
                    templatesLoadError = nil
                }
            } catch {
                await MainActor.run { templatesLoadError = error.localizedDescription }
                AppLogger.shared.error("Load personal meal templates failed: \(error.localizedDescription)")
            }
        } catch {
            await MainActor.run { loadError = error.localizedDescription }
            AppLogger.shared.error("Frequent foods load failed: \(error.localizedDescription)")
        }
    }

    @ViewBuilder
    private func sections(_ page: PersonalFoodStore.FrequentPage) -> some View {
        let hasNothing = page.matchedFoods.isEmpty && page.recipes.isEmpty && page.pendingCandidates.isEmpty && templates.isEmpty
        if let templatesLoadError {
            HMInlineRecovery(
                title: "固定菜品读取失败",
                message: "饮食记录与常吃统计不受影响；可以重试读取。",
                technicalDetails: templatesLoadError,
                actionTitle: "重试",
                onAction: { Task { await load() } }
            )
        }
        if hasNothing {
            HMEmptyState(
                title: window == .recent ? "近 30 天还没有常吃记录" : "还没有可整理的记录",
                message: "保存餐次后，这里会自动整理常吃食物；也可以先添加固定菜品。",
                icon: "fork.knife.circle",
                tone: .neutral,
                primaryActionTitle: nil,
                secondaryActionTitle: nil
            )
        } else {
            if !templates.isEmpty {
                sectionHeader("我的固定菜品")
                templateRows(templates)
            }
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
                Text("以下来自你的真实记录；可以匹配官方食材、生成配方，或保存为固定菜品。")
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
        .background(HMColors.surface, in: RoundedRectangle(cornerRadius: HMRadius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HMRadius.panel, style: .continuous).stroke(HMColors.separator, lineWidth: 1))
    }

    private func matchedFoodRow(_ matched: PersonalFoodStore.MatchedFood) -> some View {
        let food = matched.food
        let entry = food.catalogEntryId.flatMap { catalogStore.entry(id: $0) }
        let isAlreadyFixed = hasTemplate(named: food.displayName)
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
            Text("\(window.title)记录 \(matched.recentMealCount) 餐 · 官方参考")
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
            }
            HStack(spacing: 8) {
                Button {
                    togglePin(matched)
                } label: {
                    Label(food.pinned ? "取消置顶" : "置顶", systemImage: food.pinned ? "pin.slash" : "pin")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
                if isAlreadyFixed {
                    Label("已固定", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(HMColors.confirmed)
                } else if matched.recentMealCount >= 2 {
                    Button {
                        createFixedDish(from: matched, entry: entry)
                    } label: {
                        Label("固定为菜品", systemImage: "bookmark")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("nutrition-frequent-template-\(food.id ?? -1)")
                }
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

    private func createFixedDish(from matched: PersonalFoodStore.MatchedFood, entry: FoodCatalogEntry?) {
        let food = matched.food
        guard matched.recentMealCount >= 2, !hasTemplate(named: food.displayName) else { return }
        if let entry {
            let draft = MealItemDraft.fromMatchedFood(
                food,
                entry: entry,
                catalogVersion: food.catalogVersion ?? catalogStore.catalog.source.edition,
                grams: food.defaultGrams ?? matched.recentCommonGrams
            )
            onCreateTemplate(food.displayName, [draft])
        } else {
            createFixedDishFromHistory(name: food.displayName, keys: food.matchKeys)
        }
    }

    private func createFixedDishFromHistory(name: String, keys: [String]) {
        Task {
            do {
                guard let latest = try await environment.mealStore.latestItem(
                    matchingKeys: keys,
                    windowDays: page?.windowDays
                ) else {
                    await MainActor.run { actionErrorMessage = "找不到对应的历史分项，请刷新常吃统计后重试。" }
                    return
                }
                await MainActor.run {
                    onCreateTemplate(name, [MealItemDraft(record: latest)])
                }
            } catch {
                await MainActor.run { actionErrorMessage = error.localizedDescription }
            }
        }
    }

    private func hasTemplate(named name: String) -> Bool {
        let key = MealItemDraft.normalizedName(name)
        guard !key.isEmpty else { return false }
        return templates.contains { MealItemDraft.normalizedName($0.displayName) == key }
    }

    private func templateRows(_ items: [PersonalMealTemplateStore.Template]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.displayName).font(.body.weight(.medium))
                        Spacer(minLength: 8)
                        Text("\(item.items.count) 个分项")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(item.items.map(\.name).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Button {
                            onAddToMeal(item.items.map(MealItemDraft.init(templateItem:)))
                        } label: {
                            Label("加入饮食", systemImage: "plus.circle.fill")
                                .font(.footnote.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .tint(HMColors.primaryAction)
                        .accessibilityIdentifier("nutrition-template-add-\(item.id)")

                        Button {
                            onEditTemplate(item)
                        } label: {
                            Label("编辑", systemImage: "slider.horizontal.3")
                                .font(.footnote.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("nutrition-template-edit-\(item.id)")

                        Button(role: .destructive) {
                            templateToDelete = item
                        } label: {
                            Label("删除", systemImage: "trash")
                                .font(.footnote.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("nutrition-template-delete-\(item.id)")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                if index < items.count - 1 {
                    Divider().overlay(HMColors.separator).padding(.leading, 14)
                }
            }
        }
        .background(HMColors.surface, in: RoundedRectangle(cornerRadius: HMRadius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HMRadius.panel, style: .continuous).stroke(HMColors.separator, lineWidth: 1))
    }

    private func deleteTemplate(_ template: PersonalMealTemplateStore.Template) async {
        do {
            try await environment.personalMealTemplateStore.delete(id: template.id)
            await load()
        } catch {
            await MainActor.run { actionErrorMessage = error.localizedDescription }
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
        .background(HMColors.surface, in: RoundedRectangle(cornerRadius: HMRadius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HMRadius.panel, style: .continuous).stroke(HMColors.separator, lineWidth: 1))
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
                Text("近 30 天记录 \(item.recentMealCount) 餐 · 我的配方估算")
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
        .background(HMColors.surface, in: RoundedRectangle(cornerRadius: HMRadius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HMRadius.panel, style: .continuous).stroke(HMColors.separator, lineWidth: 1))
    }

    private func candidateRow(_ candidate: FrequentFoodsQuery.Summary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(candidate.displayName)
                    .font(.body.weight(.medium))
                Spacer(minLength: 8)
                Text("\(window.title)记录 \(candidate.mealCount) 餐")
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
            }
            HStack(spacing: 8) {
                if hasTemplate(named: candidate.displayName) {
                    Label("已固定", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(HMColors.confirmed)
                } else if candidate.mealCount >= 2 {
                    Button {
                        createFixedDishFromHistory(name: candidate.displayName, keys: [candidate.key])
                    } label: {
                        Label("固定为菜品", systemImage: "bookmark")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("nutrition-candidate-template-\(candidate.key)")
                }
                Spacer(minLength: 0)
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
