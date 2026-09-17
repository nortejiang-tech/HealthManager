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

/// 「营养表」页：参考食材（离线官方目录）与我的常吃两段切换。
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
        case recipeCreate(matchKey: String?, suggestedName: String)
        case recipeEdit(PersonalFoodStore.RecipeWithVersion)

        var id: String {
            switch self {
            case .detail(let entry): return "detail-\(entry.id)"
            case .editor(let items): return "editor-\(items.map(\.name).joined(separator: "|"))"
            case .sourceInfo: return "source-info"
            case .candidateMatch(let summary): return "candidate-match-\(summary.key)"
            case .recipeCreate(let key, let name): return "recipe-create-\(key ?? name)"
            case .recipeEdit(let item): return "recipe-edit-\(item.recipe.id ?? -1)-v\(item.version.version)"
            }
        }
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

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("营养表")
                .toolbar {
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
                .sheet(item: $activeSheet, onDismiss: {
                    // 候选确认/配方保存可能改变「我的常吃」，关闭任意面板后刷新。
                    frequentRefreshToken += 1
                }) { sheet in
                    switch sheet {
                    case .detail(let entry):
                        NutritionDetailView(
                            entry: entry,
                            catalog: catalogStore?.catalog,
                            onAddToMeal: { draft in
                                activeSheet = .editor([draft])
                            }
                        )
                    case .editor(let items):
                        MealEditView(prefilledItems: items)
                    case .sourceInfo:
                        NutritionSourceInfoView(source: catalogStore?.catalog.source)
                    case .candidateMatch(let summary):
                        if let catalogStore {
                            CatalogPickerSheet(
                                catalogStore: catalogStore,
                                title: "匹配官方条目",
                                subtitle: "为「\(summary.displayName)」选择官方条目。名称相近不等于同物；确认后该候选按所选条目计算。",
                                onPick: { entry in
                                    Task { await confirmCandidate(summary, entry: entry) }
                                },
                                onCancel: { activeSheet = nil }
                            )
                        }
                    case .recipeCreate(let matchKey, let suggestedName):
                        if let catalogStore {
                            RecipeEditorView(
                                catalogStore: catalogStore,
                                mode: .create(matchKey: matchKey, suggestedName: suggestedName),
                                onSaved: {
                                    await MainActor.run { activeSheet = nil }
                                }
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
                }
        }
    }

    @ViewBuilder
    private var content: some View {
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
                            activeSheet = .recipeCreate(matchKey: summary.key, suggestedName: summary.displayName)
                        }
                    )
                } else {
                    catalogLoadingView
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(HMColors.background.ignoresSafeArea())
        .accessibilityIdentifier("nutrition-screen")
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

    // MARK: - 参考食材

    @ViewBuilder
    private var referenceSection: some View {
        if let catalogError {
            catalogErrorView(catalogError)
        } else if catalogStore == nil {
            catalogLoadingView
        } else {
            NutritionReferencePanel(
                store: catalogStore!,
                query: $query,
                category: $category,
                onEntryTap: { entry in
                    activeSheet = .detail(entry)
                }
            )
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

/// 参考食材段：搜索 + 分类筛选 + 条目列表。
struct NutritionReferencePanel: View {
    let store: FoodCatalogStore
    @Binding var query: String
    @Binding var category: FoodCatalogCategory?
    let onEntryTap: (FoodCatalogEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索食物或别名", text: $query)
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

            categoryChips

            Text("每 100 g 可食部分")
                .font(.caption)
                .foregroundStyle(.secondary)

            entryList
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部", isSelected: category == nil) {
                    category = nil
                }
                ForEach(FoodCatalogCategory.allCases, id: \.self) { candidate in
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

    private var filteredEntries: [FoodCatalogEntry] {
        store.search(query: query, category: category)
    }

    private var entryList: some View {
        let entries = filteredEntries
        return Group {
            if entries.isEmpty {
                HMEmptyState(
                    title: "没有匹配的食物",
                    message: "内置目录只包含已核对的官方条目；查不到的食物不会被猜测填充。可以试试我的常吃或直接记录。",
                    icon: "magnifyingglass",
                    tone: .neutral,
                    primaryActionTitle: nil,
                    secondaryActionTitle: nil
                )
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            onEntryTap(entry)
                        } label: {
                            NutritionEntryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("nutrition-entry-\(entry.id)")
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
