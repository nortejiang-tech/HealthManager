import SwiftUI

/// Multi-select picker for confirmed foods, recipes, and fixed personal dishes.
struct FrequentFoodPickerSheet: View {
    private enum Kind: String, CaseIterable {
        case food = "常吃食物"
        case candidate = "待确认常吃"
        case recipe = "个人配方"
        case template = "固定菜品"
    }

    private struct Entry: Identifiable {
        let id: String
        let kind: Kind
        let title: String
        let detail: String
        let drafts: [MealItemDraft]
    }

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    let onSelect: ([MealItemDraft]) -> Void

    @State private var entries: [Entry] = []
    @State private var selectedIds: Set<String> = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("读取我的常吃…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    HMInlineRecovery(
                        title: "常吃食物读取失败",
                        message: "当前餐次草稿未修改，可以重试读取。",
                        technicalDetails: loadError,
                        actionTitle: "重试",
                        onAction: { Task { await load() } }
                    )
                    .padding(20)
                } else if entries.isEmpty {
                    HMEmptyState(
                        title: "还没有可选的常吃条目",
                        message: "在营养表的「我的常吃」中确认食物或保存固定菜品后，它们会显示在这里。",
                        icon: "fork.knife.circle",
                        tone: .neutral,
                        primaryActionTitle: nil,
                        secondaryActionTitle: nil
                    )
                    .padding(20)
                } else {
                    List {
                        ForEach(Kind.allCases, id: \.self) { kind in
                            let sectionEntries = entries.filter { $0.kind == kind }
                            if !sectionEntries.isEmpty {
                                Section(kind.rawValue) {
                                    ForEach(sectionEntries) { entry in
                                        entryRow(entry)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("从我的常吃选择")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !entries.isEmpty, loadError == nil {
                    Button {
                        let drafts = entries
                            .filter { selectedIds.contains($0.id) }
                            .flatMap(\.drafts)
                        onSelect(drafts)
                        dismiss()
                    } label: {
                        Text(selectedIds.isEmpty ? "选择食物后加入" : "加入所选 \(selectedIds.count) 项")
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HMColors.primaryAction)
                    .disabled(selectedIds.isEmpty)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial)
                    .accessibilityIdentifier("meal-frequent-picker-add")
                }
            }
            .task { await load() }
        }
    }

    private func entryRow(_ entry: Entry) -> some View {
        let isSelected = selectedIds.contains(entry.id)
        return Button {
            if isSelected {
                selectedIds.remove(entry.id)
            } else {
                selectedIds.insert(entry.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? HMColors.confirmed : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("meal-frequent-picker-\(entry.id)")
        .accessibilityLabel(entry.title)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        do {
            let catalog = try FoodCatalogStore.makeDefault()
            let page = try await environment.personalFoodStore.loadFrequentPage(windowDays: nil)
            let templates = try await environment.personalMealTemplateStore.loadAll()
            let latestCandidates = try await environment.mealStore.latestItems(
                matchingKeys: page.pendingCandidates.map(\.key),
                windowDays: nil
            )
            var loaded: [Entry] = []

            for matched in page.matchedFoods {
                guard let foodId = matched.food.id,
                      let catalogId = matched.food.catalogEntryId,
                      let catalogEntry = catalog.entry(id: catalogId) else { continue }
                let grams = matched.food.defaultGrams ?? matched.recentCommonGrams
                let draft = MealItemDraft.fromMatchedFood(
                    matched.food,
                    entry: catalogEntry,
                    catalogVersion: matched.food.catalogVersion ?? catalog.catalog.source.edition,
                    grams: grams
                )
                loaded.append(Entry(
                    id: "food-\(foodId)",
                    kind: .food,
                    title: matched.food.displayName,
                    detail: "官方参考 · 记录 \(matched.recentMealCount) 餐",
                    drafts: [draft]
                ))
            }

            for candidate in page.pendingCandidates {
                guard let latest = latestCandidates[candidate.key] else { continue }
                loaded.append(Entry(
                    id: "candidate-\(candidate.key)",
                    kind: .candidate,
                    title: candidate.displayName,
                    detail: "\(candidate.mealCount) 餐记录 · 保留最近一次营养与来源",
                    drafts: [MealItemDraft(record: latest)]
                ))
            }

            for recipe in page.recipes {
                guard let id = recipe.recipe.id else { continue }
                var entriesById: [String: FoodCatalogEntry] = [:]
                for ingredient in recipe.version.ingredients {
                    if let entry = catalog.entry(id: ingredient.catalogEntryId) {
                        entriesById[entry.id] = entry
                    }
                }
                let draft = MealItemDraft.fromRecipe(
                    recipe: recipe.recipe,
                    version: recipe.version,
                    entries: entriesById,
                    grams: recipe.version.outputGrams
                )
                loaded.append(Entry(
                    id: "recipe-\(id)",
                    kind: .recipe,
                    title: recipe.recipe.displayName,
                    detail: "个人配方 · v\(recipe.version.version)",
                    drafts: [draft]
                ))
            }

            loaded.append(contentsOf: templates.map { template in
                Entry(
                    id: "template-\(template.id)",
                    kind: .template,
                    title: template.displayName,
                    detail: "\(template.items.count) 个分项 · 固定菜品",
                    drafts: template.items.map(MealItemDraft.init(templateItem:))
                )
            })

            entries = loaded
            isLoading = false
        } catch {
            loadError = error.localizedDescription
            isLoading = false
            AppLogger.shared.error("Frequent food picker load failed: \(error.localizedDescription)")
        }
    }
}
