import SwiftUI

/// 营养数值展示格式（§6.4）：kcal 取整、宏量 1 位小数；计算保持原精度，仅展示舍入。
enum NutritionFormatting {
    static func kcal(_ nutrient: FoodCatalogNutrient) -> String {
        guard let value = nutrient.value else { return flagLabel(nutrient.flag) }
        return String(format: "%.0f", value)
    }

    static func macro(_ nutrient: FoodCatalogNutrient) -> String {
        guard let value = nutrient.value else { return flagLabel(nutrient.flag) }
        return String(format: "%.1f", value)
    }

    static func sodium(_ nutrient: FoodCatalogNutrient) -> String {
        guard let value = nutrient.value else { return flagLabel(nutrient.flag) }
        if value == value.rounded() { return String(format: "%.0f", value) }
        return String(value)
    }

    /// 未测定（—）与微量（微量）分别表达，不写 0；推定值以文字标注，不只靠颜色。
    static func flagLabel(_ flag: FoodCatalogNutrient.Flag) -> String {
        switch flag {
        case .unmeasured: return "—"
        case .trace: return "微量"
        case .measured, .estimated: return "0"
        }
    }

    static func isEstimated(_ nutrient: FoodCatalogNutrient) -> Bool {
        nutrient.flag == .estimated
    }
}

/// 「营养表」页：参考食材（个人参考表，可整理）与我的常吃两段切换。
/// 页面只读目录与本地统计；只有「加入饮食」→ 编辑器 → 保存才走写链路（§3 导航合同）。
struct NutritionView: View {
    enum PageSegment: String, CaseIterable, Identifiable {
        case reference
        case frequent

        var id: String { rawValue }

        var title: String {
            switch self {
            case .reference: return "参考食材"
            case .frequent: return "我的常吃"
            }
        }
    }

    private enum SheetKind: Identifiable {
        case detail(FoodCatalogEntry)
        case editor([MealItemDraft])
        case sourceInfo
        case candidateMatch(FrequentFoodsQuery.Summary)
        case recipeCreate(matchKey: String?, suggestedName: String, generated: RecipeEditorView.GeneratedPrefill?)
        case recipeEdit(PersonalFoodStore.RecipeWithVersion)
        case addFood

        var id: String {
            switch self {
            case .detail(let entry): return "detail-\(entry.id)"
            case .editor(let items): return "editor-\(items.map(\.name).joined(separator: "|"))"
            case .sourceInfo: return "source-info"
            case .candidateMatch(let summary): return "candidate-match-\(summary.key)"
            case .recipeCreate(let key, let name, _): return "recipe-create-\(key ?? name)"
            case .recipeEdit(let item): return "recipe-edit-\(item.recipe.id ?? -1)-v\(item.version.version)"
            case .addFood: return "add-food"
            }
        }
    }

    /// 移除后的撤销横幅状态。
    private struct PendingUndo: Equatable {
        let memberId: Int64
        let displayName: String
    }

    private static let segmentStorageKey = "nutrition.page.segment.v1"

    @EnvironmentObject private var environment: AppEnvironment

    @State private var segment: PageSegment = NutritionView.restoredSegment()
    @State private var query: String = ""
    @State private var category: FoodCatalogCategory?
    @State private var catalogStore: FoodCatalogStore?
    @State private var catalogError: String?
    @State private var activeSheet: SheetKind?
    @State private var frequentRefreshToken: Int = 0
    @State private var actionErrorMessage: String?

    // 参考表（成员驱动，ADR-005）
    @State private var referenceFoods: [PersonalCatalogStore.ReferenceFood] = []
    @State private var isLoadingReference: Bool = false
    @State private var referenceError: String?
    @State private var referenceToken: Int = 0
    @State private var pendingUndo: PendingUndo?
    @State private var undoExpiryTask: Task<Void, Never>?
    @State private var isGeneratingRecipe: Bool = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("营养表")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if segment == .reference {
                            Button {
                                activeSheet = .addFood
                            } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityIdentifier("nutrition-add-food")
                            .accessibilityLabel("添加食材")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            activeSheet = .sourceInfo
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .accessibilityIdentifier("nutrition-source-info")
                        .accessibilityLabel("数据来源说明")
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    undoBanner
                }
                .sheet(item: $activeSheet, onDismiss: {
                    // 候选确认/配方保存/添加食材都可能改变列表，关闭后统一刷新。
                    referenceToken += 1
                    frequentRefreshToken += 1
                }) { sheet in
                    switch sheet {
                    case .detail(let entry):
                        NutritionDetailView(
                            entry: entry,
                            catalog: catalogStore?.catalog,
                            onAddToMeal: { draft in
                                activeSheet = .editor([draft])
                            },
                            onRemove: memberID(entry) != nil ? {
                                removeMember(for: entry)
                                activeSheet = nil
                            } : nil
                        )
                    case .editor(let items):
                        MealEditView(prefilledItems: items)
                    case .sourceInfo:
                        NutritionSourceInfoView(source: catalogStore?.catalog.source)
                    case .candidateMatch(let summary):
                        if let catalogStore {
                            CatalogPickerSheet(
                                catalogStore: catalogStore,
                                personalCatalog: environment.personalCatalogStore,
                                title: "匹配官方条目",
                                subtitle: "为「\(summary.displayName)」选择官方条目。名称相近不等于同物；确认后该候选按所选条目计算。",
                                onPick: { entry in
                                    Task { await confirmCandidate(summary, entry: entry) }
                                },
                                onCancel: { activeSheet = nil }
                            )
                        }
                    case .recipeCreate(let matchKey, let suggestedName, let generated):
                        if let catalogStore {
                            RecipeEditorView(
                                catalogStore: catalogStore,
                                mode: .create(
                                    matchKey: matchKey,
                                    suggestedName: suggestedName,
                                    generated: generated
                                ),
                                onSaved: {
                                    await MainActor.run { activeSheet = nil }
                                },
                                regenerate: generated != nil ? {
                                    await regenerateSuggestion(matchKey: matchKey, suggestedName: suggestedName)
                                } : nil
                            )
                        }
                    case .recipeEdit(let item):
                        if let catalogStore {
                            RecipeEditorView(
                                catalogStore: catalogStore,
                                mode: .edit(item),
                                onSaved: {
                                    await MainActor.run { activeSheet = nil }
                                }
                            )
                        }
                    case .addFood:
                        if let catalogStore {
                            AddFoodSheet(
                                bundled: catalogStore,
                                onCancel: { activeSheet = nil },
                                onAdded: {
                                    Task { @MainActor in
                                        activeSheet = nil
                                        await refreshReference(scrollToEnd: true)
                                    }
                                }
                            )
                        }
                    }
                }
                .alert("操作失败", isPresented: .init(
                    get: { actionErrorMessage != nil },
                    set: { if !$0 { actionErrorMessage = nil } }
                )) {
                    Button("确定", role: .cancel) { actionErrorMessage = nil }
                } message: {
                    Text(actionErrorMessage ?? "")
                }
                .task {
                    await loadCatalogIfNeeded()
                    await refreshReference()
                }
                .onChange(of: segment) { _, _ in
                    if segment == .reference {
                        Task { await refreshReference() }
                    }
                }
        }
    }

    private var memberID: (FoodCatalogEntry) -> Int64? { { entry in
        referenceFoods.first { $0.entry.id == entry.id }?.member.id
    } }

    @ViewBuilder
    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    segmentPicker

                    if segment == .reference {
                        referenceSection
                    } else if let catalogError {
                        catalogErrorView(catalogError)
                    } else if let catalogStore {
                        MyFrequentPanel(
                            catalogStore: catalogStore,
                            refreshToken: frequentRefreshToken,
                            onAddToMeal: { items in
                                activeSheet = .editor(items)
                            },
                            onMatchCandidate: { summary in
                                activeSheet = .candidateMatch(summary)
                            },
                            onEditRecipe: { item in
                                activeSheet = .recipeEdit(item)
                            },
                            onCreateRecipe: { summary in
                                activeSheet = .recipeCreate(matchKey: summary.key, suggestedName: summary.displayName, generated: nil)
                            },
                            onGenerateRecipe: { summary in
                                Task { await generateRecipeDraft(for: summary) }
                            }
                        )
                        if isGeneratingRecipe {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在按常见家常做法推测配方…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                        }
                    } else {
                        catalogLoadingView
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .onChange(of: referenceToken) { _, _ in
                // 添加成功后定位新条目（列表按加入时间排序，新条目在末尾）。
                if let last = referenceFoods.last {
                    proxy.scrollTo("ref-\(last.entry.id)", anchor: .bottom)
                }
            }
        }
        .background(HMColors.background.ignoresSafeArea())
        .accessibilityIdentifier("nutrition-screen")
    }

    private var segmentPicker: some View {
        Picker("页面段", selection: $segment) {
            ForEach(PageSegment.allCases) { segment in
                Text(segment.title).tag(segment)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: segment) { _, newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.segmentStorageKey)
        }
    }

    // MARK: - 参考食材（我的参考表）

    @ViewBuilder
    private var referenceSection: some View {
        if catalogStore == nil {
            catalogLoadingView
        } else if isLoadingReference, referenceFoods.isEmpty {
            VStack(spacing: 10) {
                HMLoadingSkeleton(height: 44)
                HMLoadingSkeleton(height: 44)
                HMLoadingSkeleton(height: 44)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("正在读取参考食材")
        } else if let referenceError {
            HMInlineRecovery(
                title: "参考食材读取失败",
                message: "已保存的记录与配方不受影响；可以重试读取。",
                technicalDetails: referenceError,
                actionTitle: "重试",
                onAction: {
                    Task { await refreshReference() }
                }
            )
        } else {
            NutritionReferencePanel(
                foods: referenceFoods,
                query: $query,
                category: $category,
                onEntryTap: { entry in
                    activeSheet = .detail(entry)
                },
                onRemove: { food in
                    removeFood(food)
                },
                onAddTap: {
                    activeSheet = .addFood
                }
            )
        }
    }

    /// 移除：立即隐藏 + 撤销横幅（可逆，不弹确认）；重复移除幂等。
    private func removeFood(_ food: PersonalCatalogStore.ReferenceFood) {
        guard let memberId = food.member.id else { return }
        Task {
            do {
                try await environment.personalCatalogStore.removeMember(id: memberId)
                await MainActor.run {
                    withAnimation(.snappy) {
                        referenceFoods.removeAll { $0.member.id == memberId }
                    }
                    pendingUndo = PendingUndo(memberId: memberId, displayName: food.member.displayName)
                    scheduleUndoExpiry()
                }
            } catch {
                await MainActor.run { actionErrorMessage = error.localizedDescription }
            }
        }
    }

    private func removeMember(for entry: FoodCatalogEntry) {
        if let food = referenceFoods.first(where: { $0.entry.id == entry.id }) {
            removeFood(food)
        }
    }

    private func undoRemove() async {
        guard let pending = pendingUndo else { return }
        do {
            try await environment.personalCatalogStore.restoreMember(id: pending.memberId)
            pendingUndo = nil
            await refreshReference()
        } catch {
            await MainActor.run { actionErrorMessage = error.localizedDescription }
        }
    }

    private func scheduleUndoExpiry() {
        undoExpiryTask?.cancel()
        undoExpiryTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run { pendingUndo = nil }
        }
    }

    @ViewBuilder
    private var undoBanner: some View {
        if let pending = pendingUndo {
            HStack(spacing: 10) {
                Text("已移除「\(pending.displayName)」")
                    .font(.footnote)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("撤销") {
                    Task { await undoRemove() }
                }
                .font(.footnote.weight(.bold))
                .accessibilityIdentifier("nutrition-undo-remove")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider().overlay(HMColors.separator) }
        }
    }

    private func refreshReference(scrollToEnd: Bool = false) async {
        await MainActor.run {
            isLoadingReference = referenceFoods.isEmpty
            referenceError = nil
        }
        do {
            let foods = try await environment.personalCatalogStore.activeMembers()
            await MainActor.run {
                referenceFoods = foods
                isLoadingReference = false
                if scrollToEnd { referenceToken += 1 }
            }
        } catch {
            await MainActor.run {
                referenceError = error.localizedDescription
                isLoadingReference = false
            }
            AppLogger.shared.error("Reference foods load failed: \(error.localizedDescription)")
        }
    }

    /// 「生成参考配方」编排（§5.2）：先匹配官方候选池，再请模型推测；
    /// 失败时保留手动建立配方入口（打开空白编辑器）。
    private func generateRecipeDraft(for summary: FrequentFoodsQuery.Summary) {
        guard !isGeneratingRecipe else { return }
        guard RecipeSuggestionService.makeDefault() != nil, LLMConfig.enabled else {
            activeSheet = .recipeCreate(matchKey: summary.key, suggestedName: summary.displayName, generated: nil)
            actionErrorMessage = RecipeSuggestionService.SuggestionError.notConfigured.localizedDescription
            return
        }
        isGeneratingRecipe = true
        Task {
            defer { isGeneratingRecipe = false }
            guard let catalogStore else { return }
            let searchService = FoodSearchService(bundled: catalogStore, personalCatalog: environment.personalCatalogStore)
            let pool = await searchService.ingredientPool(forDishName: summary.displayName)
            let history = "近30天记录 \(summary.mealCount) 餐；常见份量 \(summary.commonGrams.map { "\(Int($0))g" } ?? "未记录")（历史份量为 AI 估计值，非称重事实）"
            do {
                guard let suggestionService = RecipeSuggestionService.makeDefault() else { return }
                let suggestion = try await suggestionService.suggest(
                    dishName: summary.displayName,
                    candidates: pool,
                    historyContext: history
                )
                let prefill = RecipeEditorView.GeneratedPrefill(
                    ingredients: suggestion.ingredients + suggestion.pendingNames.map { name in
                        RecipeIngredient(
                            catalogEntryId: "",
                            catalogVersion: "",
                            nameZh: name,
                            basis: .per100g,
                            preparationState: .unknown,
                            grams: nil,
                            amountStatus: .unknown,
                            nutritionSnapshot: nil,
                            pendingName: name
                        )
                    },
                    outputGrams: suggestion.outputGrams,
                    rationale: suggestion.rationale
                )
                await MainActor.run {
                    activeSheet = .recipeCreate(
                        matchKey: summary.key,
                        suggestedName: summary.displayName,
                        generated: prefill
                    )
                }
            } catch {
                await MainActor.run {
                    actionErrorMessage = "\(error.localizedDescription) 已打开手动配方。"
                    activeSheet = .recipeCreate(matchKey: summary.key, suggestedName: summary.displayName, generated: nil)
                }
            }
        }
    }

    private func regenerateSuggestion(matchKey: String?, suggestedName: String) async -> RecipeEditorView.GeneratedPrefill? {
        guard let catalogStore else { return nil }
        let searchService = FoodSearchService(bundled: catalogStore, personalCatalog: environment.personalCatalogStore)
        let pool = await searchService.ingredientPool(forDishName: suggestedName)
        guard let suggestionService = RecipeSuggestionService.makeDefault() else { return nil }
        do {
            let suggestion = try await suggestionService.suggest(
                dishName: suggestedName,
                candidates: pool,
                historyContext: ""
            )
            return RecipeEditorView.GeneratedPrefill(
                ingredients: suggestion.ingredients + suggestion.pendingNames.map { name in
                    RecipeIngredient(
                        catalogEntryId: "",
                        catalogVersion: "",
                        nameZh: name,
                        basis: .per100g,
                        preparationState: .unknown,
                        grams: nil,
                        amountStatus: .unknown,
                        nutritionSnapshot: nil,
                        pendingName: name
                    )
                },
                outputGrams: suggestion.outputGrams,
                rationale: suggestion.rationale
            )
        } catch {
            await MainActor.run { actionErrorMessage = error.localizedDescription }
            return nil
        }
    }

    private func confirmCandidate(_ summary: FrequentFoodsQuery.Summary, entry: FoodCatalogEntry) async {
        guard let catalogStore else { return }
        do {
            _ = try await environment.personalFoodStore.confirmCandidate(
                key: summary.key,
                displayName: summary.displayName,
                entry: entry,
                catalogVersion: catalogStore.catalog.source.edition
            )
            await MainActor.run {
                activeSheet = nil
                frequentRefreshToken += 1
            }
        } catch {
            await MainActor.run {
                actionErrorMessage = error.localizedDescription
            }
            AppLogger.shared.error("Confirm candidate failed: \(error.localizedDescription)")
        }
    }

    private var catalogLoadingView: some View {
        VStack(spacing: 10) {
            HMLoadingSkeleton(height: 44)
            HMLoadingSkeleton(height: 44)
            HMLoadingSkeleton(height: 44)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在读取营养目录")
    }

    private func catalogErrorView(_ message: String) -> some View {
        HMInlineRecovery(
            title: "营养目录读取失败",
            message: "内置官方目录未能加载；不会显示任何猜测数值。可重试加载。",
            technicalDetails: message,
            actionTitle: "重试",
            onAction: {
                Task { await loadCatalogIfNeeded(force: true) }
            },
            titleAccessibilityIdentifier: "nutrition-catalog-error",
            actionAccessibilityIdentifier: "nutrition-catalog-retry"
        )
    }

    private func loadCatalogIfNeeded(force: Bool = false) async {
        if catalogStore != nil, !force { return }
        await MainActor.run {
            catalogError = nil
        }
        do {
            let store = try FoodCatalogStore.makeDefault()
            await MainActor.run {
                catalogStore = store
            }
        } catch {
            await MainActor.run {
                catalogError = FoodCatalogError.userFacing(error)
            }
            AppLogger.shared.error("Food catalog load failed: \(error.localizedDescription)")
        }
    }

    private static func restoredSegment() -> PageSegment {
        guard let raw = UserDefaults.standard.string(forKey: segmentStorageKey),
              let restored = PageSegment(rawValue: raw) else {
            return .reference
        }
        return restored
    }
}

extension FoodCatalogError {
    /// 面向用户的目录错误文案：明确不显示假 0 / 猜测值（A12）。
    static func userFacing(_ error: Error) -> String {
        (error as? FoodCatalogError)?.errorDescription ?? "内置营养目录无法读取"
    }
}

/// 参考食材段：搜索（限当前参考表）+ 分类筛选 + 可整理列表（左滑移除）。
struct NutritionReferencePanel: View {
    let foods: [PersonalCatalogStore.ReferenceFood]
    @Binding var query: String
    @Binding var category: FoodCatalogCategory?
    let onEntryTap: (FoodCatalogEntry) -> Void
    let onRemove: (PersonalCatalogStore.ReferenceFood) -> Void
    let onAddTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索我的参考食材", text: $query)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("nutrition-search")
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(HMColors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(HMColors.separator, lineWidth: 1)
            )

            if !foods.isEmpty {
                categoryChips
                Text("每 100 g 可食部分")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            entryList
        }
    }

    private var presentCategories: [FoodCatalogCategory] {
        var seen: Set<FoodCatalogCategory> = []
        for food in foods where seen.insert(food.entry.category).inserted {}
        return FoodCatalogCategory.allCases.filter { seen.contains($0) }
    }

    private var filteredFoods: [PersonalCatalogStore.ReferenceFood] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return foods.filter { food in
            if let category, food.entry.category != category { return false }
            guard !trimmed.isEmpty else { return true }
            if food.member.displayName.lowercased().contains(trimmed) { return true }
            if food.entry.nameZh.lowercased().contains(trimmed) { return true }
            if food.entry.nameOriginal.lowercased().contains(trimmed) { return true }
            return food.aliases.contains { $0.lowercased().contains(trimmed) }
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部", isSelected: category == nil) {
                    category = nil
                }
                ForEach(presentCategories, id: \.self) { candidate in
                    chip(title: candidate.displayName, isSelected: category == candidate) {
                        category = candidate
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("nutrition-category-chips")
    }

    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2.bold())
                }
                Text(title)
                    .font(.footnote.weight(isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isSelected ? HMColors.comparison.opacity(0.14) : HMColors.surface,
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(isSelected ? HMColors.comparison : HMColors.separator, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? HMColors.comparison : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var entryList: some View {
        let entries = filteredFoods
        return Group {
            if foods.isEmpty {
                HMEmptyState(
                    title: "还没有参考食材",
                    message: "从官方目录或 USDA 资料库添加；也可以稍后再整理。",
                    icon: "square.grid.2x2",
                    tone: .neutral,
                    primaryActionTitle: "添加食材",
                    primaryAction: {
                        onAddTap()
                    }
                )
                .padding(.vertical, 24)
            } else if entries.isEmpty {
                HMEmptyState(
                    title: "没有匹配的食材",
                    message: "当前参考表中没有匹配项；「＋」可搜索资料库并添加新食材。",
                    icon: "magnifyingglass",
                    tone: .neutral,
                    primaryActionTitle: nil,
                    secondaryActionTitle: nil
                )
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.entry.id) { index, food in
                        SwipeToRemoveRow {
                            Button {
                                onEntryTap(food.entry)
                            } label: {
                                NutritionEntryRow(entry: food.entry)
                            }
                            .buttonStyle(.plain)
                        } onRemove: {
                            onRemove(food)
                        }
                        .accessibilityIdentifier("nutrition-entry-\(food.entry.id)")
                        if index < entries.count - 1 {
                            Divider().overlay(HMColors.separator).padding(.leading, 4)
                        }
                    }
                }
                .background(HMColors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(HMColors.separator, lineWidth: 1)
                )
            }
        }
    }
}

/// 目录行：名称+生熟/加工状态、热量大数右对齐；第二行蛋白/脂肪/碳水。
struct NutritionEntryRow: View {
    let entry: FoodCatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.nameZh)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(entry.preparationState.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(NutritionFormatting.kcal(entry.nutrients.kcal))
                        .font(.body.bold().monospacedDigit())
                    Text("kcal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Text("蛋白质 \(NutritionFormatting.macro(entry.nutrients.proteinG)) g")
                Text("脂肪 \(NutritionFormatting.macro(entry.nutrients.fatG)) g")
                Text("碳水 \(NutritionFormatting.macro(entry.nutrients.carbsG)) g")
                Spacer()
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text("\(entry.basis.displayUnit) · \(entry.source) 官方成分表")
                if NutritionFormatting.isEstimated(entry.nutrients.kcal) {
                    Text("含官方推定值")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// 来源说明（标题旁 info 入口）：机构、数据集版本、署名要求。
struct NutritionSourceInfoView: View {
    let source: FoodCatalog.SourceInfo?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let source {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(source.title)
                                .font(.title3.weight(.semibold))
                            Text("提供机构：\(source.agency)（日本文部科学省）")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("数据版本：\(source.edition)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("核对日期：\(source.downloadedAt)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .hmSurface(cornerRadius: 18)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("使用说明")
                                .font(.subheadline.weight(.semibold))
                            Text("数值为每 100 g 可食部分的官方发布值，App 不以 4/4/9 重算能量；官方标注的推定值、微量与未测定项分别保留。")
                            Text("目录只包含经过逐条核对的食材。查不到的食物不会编造数值，可在个人配方中按食材组合计算。")
                            Text(source.termsOfUse)
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .hmSurface(cornerRadius: 18)
                    } else {
                        Text("目录尚未加载，无法显示来源信息。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle("数据来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
