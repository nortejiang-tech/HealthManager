import SwiftUI

/// 「添加食材」（§3.2）：输入名称 → 本地即时过滤 → 提交后查 USDA → 选择候选 →
/// 核验完整详情 → 添加到参考食材。单个弹出页完成，不加顶级页面。
struct AddFoodSheet: View {
    enum RemotePhase: Equatable {
        case idle
        case searching
        case done
        case failed(USDAServiceError)
    }

    enum Selection: Equatable {
        case local(FoodCatalogEntry)
        case remoteDetail(entry: FoodCatalogEntry, versionLabel: String, fdcId: Int64)
    }

    @EnvironmentObject private var environment: AppEnvironment

    let bundled: FoodCatalogStore
    let onCancel: () -> Void
    /// 添加成功后回调（父级刷新列表并定位新条目）。
    let onAdded: () -> Void

    @State private var query: String = ""
    @State private var localResults: [FoodSearchCandidate] = []
    @State private var remoteResults: [FoodSearchCandidate] = []
    @State private var remoteQueryUsed: String = ""
    @State private var remoteTermSource: String = ""
    @State private var remotePhase: RemotePhase = .idle
    @State private var generation: Int = 0
    @State private var localDebounce: Task<Void, Never>?
    @State private var selection: Selection?
    @State private var detailLoading: Bool = false
    @State private var detailError: String?
    @State private var memberStates: [String: Bool] = [:]
    @State private var addedIds: Set<String> = []
    @State private var displayName: String = ""
    @State private var isAdding: Bool = false
    @State private var addError: String?

    private var searchService: FoodSearchService {
        FoodSearchService(bundled: bundled, personalCatalog: environment.personalCatalogStore)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let selection {
                    detailPane(selection)
                } else {
                    searchPane
                }
            }
            .navigationTitle("添加食材")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                        .accessibilityIdentifier("add-food-cancel")
                }
            }
        }
        .task {
            await runLocalSearch()
        }
    }

    // MARK: - 搜索面板

    private var searchPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索食物，如黑巧克力", text: $query)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .accessibilityIdentifier("add-food-search")
                    .onSubmit { submitRemote() }
                    .onChange(of: query) { _, _ in
                        scheduleLocalSearch()
                    }
                Button {
                    submitRemote()
                } label: {
                    Text("搜索")
                        .font(.footnote.weight(.semibold))
                }
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("add-food-submit")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(HMColors.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(HMColors.separator, lineWidth: 1))

            Text("本地结果即时显示；按「搜索」继续查询 USDA 资料库。")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !localResults.isEmpty {
                        Text("本地结果")
                            .font(.subheadline.weight(.semibold))
                        ForEach(localResults) { candidate in
                            candidateRow(candidate)
                        }
                    } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("本地目录没有匹配；可提交搜索联网资料库。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    remoteSection
                }
                .padding(.bottom, 24)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var remoteSection: some View {
        switch remotePhase {
        case .idle:
            EmptyView()
        case .searching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在查询 USDA 资料库…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        case .done:
            if remoteResults.isEmpty {
                Text("USDA 资料库没有匹配；可换关键词（如 dark chocolate）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                Text("USDA 资料库 · 检索词「\(remoteQueryUsed)」（\(remoteTermSource)）")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 6)
                ForEach(remoteResults) { candidate in
                    candidateRow(candidate)
                }
            }
        case .failed(let error):
            VStack(alignment: .leading, spacing: 6) {
                Text(error.localizedDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !USDAKeyStore.isConfigured {
                    Text("配置路径：更多 → 设置 → 食材资料库。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 8)
        }
    }

    private func candidateRow(_ candidate: FoodSearchCandidate) -> some View {
        Button {
            select(candidate)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(candidate.title)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    memberBadge(candidate)
                }
                Text(candidate.qualifiers)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let tierLabel = candidate.tier.label {
                    Text(tierLabel)
                        .font(.caption2)
                        .foregroundStyle(HMColors.estimate)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(HMColors.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(HMColors.separator, lineWidth: 1))
        .accessibilityIdentifier("add-food-candidate-\(candidate.id)")
    }

    @ViewBuilder
    private func memberBadge(_ candidate: FoodSearchCandidate) -> some View {
        if addedIds.contains(candidate.id) {
            badge("已添加", tone: .confirmed)
        } else if let state = memberStates[candidate.id] {
            if state {
                badge("已添加", tone: .confirmed)
            } else {
                badge("重新添加", tone: .comparison)
            }
        } else if candidate.isRemote {
            EmptyView()
        }
    }

    private func badge(_ text: String, tone: HMSemanticTone) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tone.color.opacity(0.14), in: Capsule())
            .foregroundStyle(tone.color)
    }

    // MARK: - 详情面板（S3：详情取得后才可添加）

    private func detailPane(_ selection: Selection) -> some View {
        let entry: FoodCatalogEntry
        let versionLabel: String
        switch selection {
        case .local(let entryValue):
            entry = entryValue
            versionLabel = bundled.catalog.source.edition
        case .remoteDetail(let entryValue, let label, _):
            entry = entryValue
            versionLabel = label
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.nameZh)
                        .font(.title3.weight(.bold))
                        .lineLimit(3)
                    Text(entry.nameOriginal)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(entry.note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    Text("每 100 g 可食部分")
                        .font(.subheadline.weight(.semibold))
                    nutrientLine("热量", value: NutritionFormatting.kcal(entry.nutrients.kcal), unit: "kcal", nutrient: entry.nutrients.kcal)
                    nutrientLine("蛋白质", value: NutritionFormatting.macro(entry.nutrients.proteinG), unit: "g", nutrient: entry.nutrients.proteinG)
                    nutrientLine("脂肪", value: NutritionFormatting.macro(entry.nutrients.fatG), unit: "g", nutrient: entry.nutrients.fatG)
                    nutrientLine("碳水", value: NutritionFormatting.macro(entry.nutrients.carbsG), unit: "g", nutrient: entry.nutrients.carbsG)
                    ForEach(entry.portions, id: \.description) { portion in
                        let scaled = FoodServingCalculator.scaled(entry.nutrients, serving: portion.gramWeight)
                        HStack(alignment: .firstTextBaseline) {
                            Text("每份（\(portion.description) · \(Self.portionGramsText(portion))g）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(scaled.map { "\(NutritionFormatting.kcal($0.kcal)) kcal · P \(NutritionFormatting.macro($0.proteinG))g · F \(NutritionFormatting.macro($0.fatG))g · C \(NutritionFormatting.macro($0.carbsG))g" } ?? "—")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    DisclosureGroup("更多营养与出处") {
                        nutrientLine("膳食纤维", value: NutritionFormatting.macro(entry.nutrients.fiberG), unit: "g", nutrient: entry.nutrients.fiberG)
                        nutrientLine("钠", value: NutritionFormatting.sodium(entry.nutrients.sodiumMg), unit: "mg", nutrient: entry.nutrients.sodiumMg)
                        Text("来源：\(entry.source) · \(entry.foodNo)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(entry.sourceUrl)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                    .font(.subheadline)
                }
                .padding(16)
                .hmSurface(cornerRadius: 18)

                VStack(alignment: .leading, spacing: 8) {
                    Text("显示名（可改）")
                        .font(.subheadline.weight(.semibold))
                    TextField("如：常买的黑巧", text: $displayName)
                        .accessibilityIdentifier("add-food-display-name")
                    Text("只改你在列表里的叫法；原始名称、来源和营养值不变。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .hmSurface(cornerRadius: 18)

                if let addError {
                    Text(addError)
                        .font(.footnote)
                        .foregroundStyle(HMColors.actionRequired)
                }

                Button {
                    Task { await add(selection: selection, entry: entry, versionLabel: versionLabel) }
                } label: {
                    HStack(spacing: 8) {
                        if isAdding {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Text(addButtonTitle)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(HMColors.primaryAction)
                .disabled(isAdding || !entry.basisAllNutrientsUsable)
                .accessibilityIdentifier("add-food-confirm")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var addButtonTitle: String {
        let id = currentCandidateId
        if addedIds.contains(id) { return "已添加 · 返回" }
        if memberStates[id] == false { return "重新添加到参考食材" }
        return "添加到参考食材"
    }

    private var currentCandidateId: String {
        switch selection {
        case .local(let entry): return entry.id
        case .remoteDetail(let entry, _, _): return entry.id
        case nil: return ""
        }
    }

    private func nutrientLine(_ label: String, value: String, unit: String, nutrient: FoodCatalogNutrient) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
            if NutritionFormatting.isEstimated(nutrient) {
                Text("推定")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 行为

    private func scheduleLocalSearch() {
        localDebounce?.cancel()
        localDebounce = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await runLocalSearch()
        }
    }

    private func runLocalSearch() async {
        let currentGeneration = generation
        let results = await searchService.searchLocal(query: query)
        guard currentGeneration == generation else { return }
        await MainActor.run {
            localResults = results
            refreshMemberStates(for: results)
        }
    }

    /// 提交才查远端，不对每个按键发请求（§3.2-1）。
    /// 跨语言（§3.3）：USDA 无中文数据——先查内置词典，再由已配置文本模型
    /// 辅助翻译检索词（模型只产出检索词，不产出营养值）；都不可用回退原词。
    private func submitRemote() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        generation += 1
        let currentGeneration = generation
        remotePhase = .searching
        remoteResults = []
        remoteQueryUsed = trimmed
        remoteTermSource = "原词"
        let client = USDAApiClient(fetcher: USDAApiClient.defaultFetcher())
        Task {
            // 1) 本地词典
            var searchTerm = CrossLanguageSearchTermService.dictionaryTerm(
                for: trimmed,
                dictionary: CrossLanguageSearchTermService.loadDictionary()
            )
            var termSource = searchTerm != nil ? "词典" : "原词"
            // 2) 已配置文本模型辅助翻译（词典未覆盖时，一次性调用）
            if searchTerm == nil, LLMConfig.enabled,
               let suggestionService = RecipeSuggestionService.makeDefault() {
                if let translated = try? await CrossLanguageSearchTermService.translatedTerm(
                    query: trimmed,
                    call: { system, user in
                        try await suggestionService.rawCall(system: system, user: user)
                    }
                ) {
                    searchTerm = translated
                    termSource = "模型翻译"
                }
            }
            let effectiveQuery = searchTerm ?? trimmed

            let result = await searchService.searchRemoteUSDA(query: effectiveQuery, client: client)
            await MainActor.run {
                // 过期响应不覆盖新查询（S5）。
                guard currentGeneration == generation else { return }
                remoteQueryUsed = effectiveQuery
                remoteTermSource = termSource
                switch result {
                case .success(let candidates):
                    remoteResults = candidates
                    remotePhase = .done
                case .failure(let error):
                    remotePhase = .failed(error)
                }
            }
        }
    }

    private func select(_ candidate: FoodSearchCandidate) {
        addError = nil
        displayName = candidate.title
        if let entry = candidate.entry {
            selection = .local(entry)
            return
        }
        guard let fdcId = candidate.remoteFdcId else { return }
        detailLoading = true
        detailError = nil
        let client = USDAApiClient(fetcher: USDAApiClient.defaultFetcher())
        Task {
            do {
                let detail = try await client.detail(fdcId: fdcId)
                let entry = try USDAFoodMapper.entry(from: detail)
                let versionLabel = USDAFoodMapper.versionLabel(for: detail)
                await MainActor.run {
                    detailLoading = false
                    selection = .remoteDetail(entry: entry, versionLabel: versionLabel, fdcId: fdcId)
                }
            } catch let error as USDAServiceError {
                await MainActor.run {
                    detailLoading = false
                    detailError = error.localizedDescription
                }
            } catch let error as USDAFoodMapper.MapError {
                await MainActor.run {
                    detailLoading = false
                    detailError = error.localizedDescription
                }
            } catch {
                await MainActor.run {
                    detailLoading = false
                    detailError = error.localizedDescription
                }
            }
        }
    }

    private func refreshMemberStates(for candidates: [FoodSearchCandidate]) {
        Task {
            for candidate in candidates where !candidate.isRemote {
                guard let identity = PersonalCatalogStore.parseIdentity(candidate.id) else { continue }
                let state = try? await environment.personalCatalogStore.membershipState(
                    provider: identity.provider,
                    providerFoodId: identity.providerFoodId
                )
                if let state {
                    await MainActor.run {
                        memberStates[candidate.id] = state
                    }
                }
            }
        }
    }

    private func add(selection: Selection, entry: FoodCatalogEntry, versionLabel: String) async {
        if addedIds.contains(currentCandidateId) {
            onAdded()
            return
        }
        isAdding = true
        addError = nil
        defer { isAdding = false }
        do {
            // 先持久化资料与成员，再返回（§3.2-6）；幂等，重复点击安全。
            _ = try await environment.personalCatalogStore.importEntries([
                PersonalCatalogStore.ImportRequest(
                    entry: entry,
                    displayName: displayName.isEmpty ? entry.nameZh : displayName,
                    versionLabel: versionLabel,
                    aliases: [],
                    activate: true
                )
            ])
            await MainActor.run {
                addedIds.insert(currentCandidateId)
                memberStates[currentCandidateId] = true
                onAdded()
            }
        } catch {
            await MainActor.run {
                addError = error.localizedDescription
            }
        }
    }
}

private extension AddFoodSheet {
    static func portionGramsText(_ portion: FoodPortion) -> String {
        let w = portion.gramWeight
        return w == w.rounded() ? String(format: "%.0f", w) : String(w)
    }
}

extension FoodCatalogEntry {
    /// 添加门槛：至少能量与三大宏量有一个可用值，且计量基准明确（§3.2-5）。
    var basisAllNutrientsUsable: Bool {
        [nutrients.kcal, nutrients.proteinG, nutrients.fatG, nutrients.carbsG]
            .contains { $0.value != nil }
    }
}
