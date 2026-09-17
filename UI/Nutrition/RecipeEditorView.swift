import SwiftUI

/// 配方编辑器（§5.3 / 阶段三）：原料（官方条目 + 用量状态）、成品重量与依据、
/// 每 100 g 预览。保存即生成新的不可变版本；取消不写任何数据。
struct RecipeEditorView: View {
    enum Mode {
        /// 从待确认候选创建（可选携带候选键，确认后映射回该候选）。
        case create(matchKey: String?, suggestedName: String)
        /// 修订既有配方：保存生成新版本，旧版本保留。
        case edit(PersonalFoodStore.RecipeWithVersion)
    }

    struct DraftIngredient: Identifiable, Equatable {
        let id = UUID()
        var ingredient: RecipeIngredient
        var gramsText: String

        var status: RecipeIngredient.AmountStatus { ingredient.amountStatus }
    }

    enum OutputBasis: String, CaseIterable, Identifiable {
        case weighed
        case estimated
        case pending

        var id: String { rawValue }
        var title: String {
            switch self {
            case .weighed: return "实称"
            case .estimated: return "估计"
            case .pending: return "待补"
            }
        }
    }

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    let catalogStore: FoodCatalogStore
    let mode: RecipeEditorView.Mode
    let onSaved: () async -> Void

    @State private var name: String
    @State private var ingredients: [DraftIngredient]
    @State private var outputText: String
    @State private var outputBasis: OutputBasis
    @State private var note: String
    @State private var matchKey: String?
    @State private var isShowingPicker = false
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        catalogStore: FoodCatalogStore,
        mode: RecipeEditorView.Mode,
        onSaved: @escaping () async -> Void
    ) {
        self.catalogStore = catalogStore
        self.mode = mode
        self.onSaved = onSaved

        switch mode {
        case .create(let key, let suggestedName):
            _name = State(initialValue: suggestedName)
            _ingredients = State(initialValue: [])
            _outputText = State(initialValue: "")
            _outputBasis = State(initialValue: .pending)
            _note = State(initialValue: "")
            _matchKey = State(initialValue: key)
        case .edit(let item):
            _name = State(initialValue: item.recipe.displayName)
            _ingredients = State(initialValue: item.version.ingredients.map { ingredient in
                DraftIngredient(
                    ingredient: ingredient,
                    gramsText: ingredient.grams.map {
                        $0 == $0.rounded() ? String(format: "%.0f", $0) : String($0)
                    } ?? ""
                )
            })
            _outputText = State(initialValue: item.version.outputGrams.map { String($0) } ?? "")
            _outputBasis = State(initialValue: OutputBasis(rawValue: item.version.outputWeightBasis ?? "") ?? .pending)
            _note = State(initialValue: item.version.note ?? "")
            _matchKey = State(initialValue: nil)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("配方名称") {
                    TextField("如：干豆腐卷大葱、早餐（鸡蛋＋豆浆）", text: $name)
                        .accessibilityIdentifier("recipe-editor-name")
                }

                Section {
                    ForEach($ingredients) { $draft in
                        ingredientRow($draft)
                    }
                    .onDelete { offsets in
                        ingredients.remove(atOffsets: offsets)
                    }

                    Button {
                        isShowingPicker = true
                    } label: {
                        Label("添加原料（官方目录）", systemImage: "plus.circle")
                    }
                    .accessibilityIdentifier("recipe-editor-add-ingredient")
                } header: {
                    Text("原料")
                } footer: {
                    Text("原料取自内置官方目录；用量需标注已称量/估计/未使用/未知——未知用量不会按 0 计算。")
                }

                Section {
                    HStack {
                        Text("成品总重量 g")
                        Spacer()
                        TextField("待补", text: $outputText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 110)
                            .accessibilityIdentifier("recipe-editor-output")
                    }
                    Picker("重量依据", selection: $outputBasis) {
                        ForEach(OutputBasis.allCases) { basis in
                            Text(basis.title).tag(basis)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("最终可食成品重量")
                } footer: {
                    Text(outputFooter)
                }

                previewSection

                Section("备注") {
                    TextField("做法、比例假设等", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("recipe-editor-error")
                    }
                }
            }
            .navigationTitle(isEditingExisting ? "修订配方" : "新建配方")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                        .accessibilityIdentifier("recipe-editor-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("保存")
                        }
                    }
                    .disabled(isSaving || !canSave)
                    .accessibilityIdentifier("recipe-editor-save")
                }
            }
            .sheet(isPresented: $isShowingPicker) {
                CatalogPickerSheet(
                    catalogStore: catalogStore,
                    title: "选择原料",
                    subtitle: "从内置官方目录挑选；未收录的食材不会出现在结果里。",
                    onPick: { entry in
                        appendIngredient(entry)
                        isShowingPicker = false
                    },
                    onCancel: { isShowingPicker = false }
                )
            }
        }
    }

    private var isEditingExisting: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var outputFooter: String {
        switch outputBasis {
        case .pending:
            return "成品重量未知时允许保存配方草稿，但每 100 g 会显示「待补成品重量」。"
        case .estimated:
            return "估计重量 → 配方按简化估算计算，显示为「我的配方估算」。"
        case .weighed:
            return "实称重量 → 每 100 g 按实际成品重计算。"
        }
    }

    private func ingredientRow(_ draft: Binding<DraftIngredient>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(draft.wrappedValue.ingredient.nameZh)
                    .font(.body)
                Spacer()
                Menu {
                    ForEach(RecipeIngredient.AmountStatus.allCases, id: \.self) { status in
                        Button(status.title) {
                            draft.wrappedValue.ingredient.amountStatus = status
                            if status == .notUsed || status == .unknown {
                                draft.wrappedValue.gramsText = ""
                            }
                        }
                    }
                } label: {
                    Label(draft.wrappedValue.status.title, systemImage: "scalemass")
                        .font(.caption)
                }
                .accessibilityLabel("用量状态：\(draft.wrappedValue.status.title)")
            }
            if draft.wrappedValue.status == .weighed || draft.wrappedValue.status == .estimated {
                HStack(spacing: 8) {
                    Text("用量")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("克", text: $draft.gramsText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityIdentifier("recipe-ingredient-grams-\(draft.wrappedValue.id)")
                    Text("g（\(draft.wrappedValue.ingredient.basis == .per100mL ? "mL 口径条目" : "每100g基准")）")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else if draft.wrappedValue.status == .notUsed {
                Text("本次未使用（按 0 计）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("用量未知——相关营养按未知处理，不按 0")
                    .font(.caption)
                    .foregroundStyle(HMColors.actionRequired)
            }
        }
        .padding(.vertical, 2)
    }

    private var previewSection: some View {
        let resolved = resolvedInputs
        let calculation = RecipeCalculator.calculate(
            ingredients: resolved.inputs,
            outputGrams: parsedOutputGrams
        )
        return Section {
            HStack {
                Text("每份合计")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(totalText(calculation.totals.caloriesKcal, unit: " kcal"))
                    .font(.body.monospacedDigit().weight(.semibold))
            }
            HStack {
                Text("P / F / C")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("""
                    \(totalText(calculation.totals.proteinG, unit: "g")) / \
                    \(totalText(calculation.totals.fatG, unit: "g")) / \
                    \(totalText(calculation.totals.carbsG, unit: "g"))
                    """)
                    .font(.body.monospacedDigit())
            }
            HStack {
                Text("每 100 g 热量")
                    .foregroundStyle(.secondary)
                Spacer()
                if let per100 = calculation.per100, let kcal = per100.caloriesKcal {
                    Text("\(String(format: "%.0f", kcal)) kcal")
                        .font(.body.monospacedDigit().weight(.semibold))
                } else {
                    Text("待补成品重量")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if calculation.isAmountUnknown {
                Label("有用量未知的原料：总量按未知显示，不会按 0。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(HMColors.actionRequired)
            } else if calculation.hasMissingNutrient {
                Label("部分原料营养字段缺失：成品对应指标显示未知。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("计算预览")
        } footer: {
            Text("结果为基于官方食材条目的简化估算，未含未量化的烹调损失；不含未量化的吸油/弃汤影响。")
        }
    }

    private func totalText(_ value: Double?, unit: String) -> String {
        guard let value else { return "—\(unit)" }
        let rounded = value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return "\(rounded)\(unit)"
    }

    private var resolvedInputs: (inputs: [RecipeCalculator.IngredientInput], missingCount: Int) {
        var inputs: [RecipeCalculator.IngredientInput] = []
        var missing = 0
        for draft in ingredients {
            guard let entry = catalogStore.entry(id: draft.ingredient.catalogEntryId) else {
                missing += 1
                continue
            }
            inputs.append(
                RecipeCalculator.IngredientInput(
                    per100: entry.nutrients,
                    grams: parsedGrams(draft),
                    status: draft.ingredient.amountStatus
                )
            )
        }
        return (inputs, missing)
    }

    private func parsedGrams(_ draft: DraftIngredient) -> Double? {
        let trimmed = draft.gramsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite, value > 0 else { return nil }
        return value
    }

    private var parsedOutputGrams: Double? {
        let trimmed = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite, value > 0 else { return nil }
        return value
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !ingredients.isEmpty
    }

    private func appendIngredient(_ entry: FoodCatalogEntry) {
        guard !ingredients.contains(where: { $0.ingredient.catalogEntryId == entry.id }) else { return }
        ingredients.append(
            DraftIngredient(
                ingredient: RecipeIngredient(
                    catalogEntryId: entry.id,
                    catalogVersion: catalogStore.catalog.source.edition,
                    nameZh: entry.nameZh,
                    basis: entry.basis,
                    preparationState: entry.mealItemState,
                    grams: nil,
                    amountStatus: .weighed
                ),
                gramsText: ""
            )
        )
    }

    private func save() async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        var outputGrams: Double?
        var basisString: String?
        if outputBasis != .pending {
            guard let grams = parsedOutputGrams else {
                saveError = "重量依据为\(outputBasis.title)时必须填写正数克数；不确定请选「待补」。"
                return
            }
            outputGrams = grams
            basisString = outputBasis.rawValue
        }

        var prepared: [RecipeIngredient] = []
        for draft in ingredients {
            var ingredient = draft.ingredient
            ingredient.grams = parsedGrams(draft)
            prepared.append(ingredient)
        }
        // 已声明称量/估计但克数非法 → 阻止保存（不能静默当未知）。
        for draft in ingredients {
            if draft.ingredient.amountStatus == .weighed || draft.ingredient.amountStatus == .estimated {
                guard parsedGrams(draft) != nil else {
                    saveError = "「\(draft.ingredient.nameZh)」已标记\(draft.ingredient.amountStatus.title)但克数无效。"
                    return
                }
            }
        }

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch mode {
            case .create:
                _ = try await environment.personalFoodStore.createRecipe(
                    name: name,
                    ingredients: prepared,
                    outputGrams: outputGrams,
                    outputWeightBasis: basisString,
                    note: trimmedNote.isEmpty ? nil : trimmedNote,
                    matchKey: matchKey
                )
            case .edit(let item):
                _ = try await environment.personalFoodStore.updateRecipe(
                    recipeId: item.recipe.id ?? 0,
                    name: name,
                    ingredients: prepared,
                    outputGrams: outputGrams,
                    outputWeightBasis: basisString,
                    note: trimmedNote.isEmpty ? nil : trimmedNote
                )
            }
            await onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

extension RecipeIngredient.AmountStatus {
    var title: String {
        switch self {
        case .weighed: return "已称量"
        case .estimated: return "估计"
        case .notUsed: return "未使用"
        case .unknown: return "未知"
        }
    }
}

/// 从内置目录挑选条目（候选匹配、配方加原料共用）。只读，不写任何数据。
struct CatalogPickerSheet: View {
    let catalogStore: FoodCatalogStore
    let title: String
    let subtitle: String
    let onPick: (FoodCatalogEntry) -> Void
    let onCancel: () -> Void

    @State private var query: String = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索食物或别名", text: $query)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("catalog-picker-search")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(HMColors.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(HMColors.separator, lineWidth: 1))

                let results = catalogStore.search(query: query, category: nil)
                if results.isEmpty {
                    Text("没有匹配的官方条目。查不到的食物不会被猜测填充。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                            Button {
                                onPick(entry)
                            } label: {
                                NutritionEntryRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("catalog-picker-option-\(entry.id)")
                            if index < results.count - 1 {
                                Divider().overlay(HMColors.separator).padding(.leading, 4)
                            }
                        }
                    }
                    .background(HMColors.surface, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(HMColors.separator, lineWidth: 1))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
            }
        }
    }
}
