import SwiftUI
import PhotosUI
import GRDB
import UIKit

private func mealNutritionText(_ value: Double) -> String {
    value == value.rounded() ? String(format: "%.0f", value) : String(value)
}

private enum DietLoadState: Equatable {
    case loading
    case loaded
    case stale
    case failed

    var hasUsableContent: Bool {
        self == .loaded || self == .stale
    }

    var showsRecovery: Bool {
        self == .failed || self == .stale
    }
}

struct DietView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var meals: [MealRecord] = []
    @State private var activeSheet: DietSheetKind?
    @State private var todayNutrition: MealNutritionEvidenceWindow?
    @State private var loadState: DietLoadState = .loading
    @State private var refreshGeneration: Int = 0
    @State private var deleteErrorMessage: String?

    private enum DietSheetKind: Identifiable, Equatable {
        case add
        case edit(MealRecord)
        case reuse

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let meal):
                return "edit-\(meal.id ?? -1)"
            case .reuse:
                return "reuse"
            }
        }
    }

    var body: some View {
        NavigationStack {
            DietScreenContent(
                loadState: loadState,
                meals: meals,
                todayNutrition: todayNutrition,
                onAdd: { activeSheet = .add },
                onReuse: { activeSheet = .reuse },
                onMealTap: { meal in
                    activeSheet = .edit(meal)
                },
                onDeleteMeal: { meal in
                    await delete(meal)
                },
                onRetry: {
                    await refresh()
                }
            )
            .navigationTitle("饮食")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        activeSheet = .add
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("diet-add-meal")
                    .accessibilityLabel("新增餐次")
                    Button {
                        activeSheet = .reuse
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("diet-reuse-meal")
                    .accessibilityLabel("复用餐次")
                }
            }
            .sheet(item: $activeSheet, onDismiss: { Task { await refresh() } }) { destination in
                switch destination {
                case .add:
                    MealEditView()
                case .edit(let meal):
                    MealEditView(editing: meal)
                case .reuse:
                    MealReuseView()
                }
            }
            .task { await refresh() }
            .refreshable { await refresh() }
            .alert("删除失败", isPresented: .init(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            )) {
                Button("确定", role: .cancel) {
                    deleteErrorMessage = nil
                }
            } message: {
                Text(deleteErrorMessage ?? "")
            }
        }
    }

    private func refresh() async {
        let (hadUsableContent, generation) = await MainActor.run {
            refreshGeneration += 1
            return (loadState.hasUsableContent, refreshGeneration)
        }
        if !hadUsableContent {
            await MainActor.run { loadState = .loading }
        }
        do {
            let (list, nutrition) = try await environment.database.asyncRead {
                db -> ([MealRecord], MealNutritionEvidenceWindow) in
                let rows = try MealRecord
                    .order(Column("eaten_at").desc)
                    .limit(50)
                    .fetchAll(db)

                let calendar = Calendar.current
                let dayStart = calendar.startOfDay(for: Date())
                let evidence = try MealNutritionEvidenceQuery.load(
                    db: db,
                    fromLocalDay: dayStart,
                    throughLocalDay: dayStart,
                    calendar: calendar
                )
                return (rows, evidence)
            }
            await MainActor.run {
                guard generation == refreshGeneration else { return }
                meals = list
                todayNutrition = nutrition
                loadState = .loaded
            }
        } catch {
            await MainActor.run {
                guard generation == refreshGeneration else { return }
                if hadUsableContent {
                    loadState = .stale
                } else {
                    todayNutrition = nil
                    loadState = .failed
                }
            }
            AppLogger.shared.error("Diet refresh failed: \(error.localizedDescription)")
        }
    }

    private func delete(_ meal: MealRecord) async {
        guard let id = meal.id else {
            await MainActor.run {
                deleteErrorMessage = "无法删除未保存餐次"
            }
            return
        }
        do {
            try await environment.mealPersistenceCoordinator.delete(mealId: id)
            environment.notifyLocalDataChanged()
            await refresh()
        } catch {
            let message = "删除失败：\(error.localizedDescription)"
            await MainActor.run {
                deleteErrorMessage = message
            }
            AppLogger.shared.error("Meal delete failed: \(error.localizedDescription)")
        }
    }
}

private struct DietScreenContent: View {
    let loadState: DietLoadState
    let meals: [MealRecord]
    let todayNutrition: MealNutritionEvidenceWindow?
    let onAdd: () -> Void
    let onReuse: () -> Void
    let onMealTap: (MealRecord) -> Void
    let onDeleteMeal: (MealRecord) async -> Void
    let onRetry: () async -> Void

    private var evidenceTone: HMSemanticTone {
        switch loadState {
        case .loading:
            return .neutral
        case .failed, .stale:
            return .actionRequired
        case .loaded:
            switch todayNutrition?.calories {
            case .incomplete:
                return .estimate
            case .complete:
                return .confirmed
            case .noMeals, .none:
                return .neutral
            }
        }
    }

    private var decisionText: String {
        switch loadState {
        case .loading:
            return "正在读取今天的营养汇总与最近餐次。"
        case .failed:
            return "暂时无法更新营养汇总；已经保存的餐次不会因此被删除。"
        case .stale:
            return "本次更新失败；下方保留上一次成功读取的餐次与营养证据。"
        case .loaded:
            guard let nutrition = todayNutrition else {
                return "今天还没有可汇总的餐次。"
            }
            if nutrition.mealCount == 0 {
                return "今天还没有可汇总的餐次；这里仅显示你主动保存的记录。"
            }
            return "已记录 \(nutrition.mealCount) 餐。完整营养项进入汇总，未提供的字段保留为“—”。"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(HMDateText.fullWeekday())
                    .font(.body)
                    .foregroundStyle(.secondary)

                HMDecisionLens(
                    title: "今日营养基线",
                    text: decisionText,
                    tone: evidenceTone,
                    systemImage: "fork.knife"
                )

                if loadState.hasUsableContent, !meals.isEmpty {
                    mealList
                    evidencePanel
                } else {
                    evidencePanel
                    mealList
                }

                if loadState.showsRecovery {
                    HMInlineRecovery(
                        title: "饮食读取失败",
                        message: loadState == .stale
                            ? "当前仍显示上一次成功读取的内容；重试只更新今日列表与营养证据。"
                            : "重试范围仅限今日列表与营养证据读取。",
                        actionTitle: "重试",
                        onAction: {
                            Task { await onRetry() }
                        },
                        actionAccessibilityIdentifier: "diet-retry"
                    )
                    .hmSurface(cornerRadius: 18)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(HMColors.background.ignoresSafeArea())
    }

    private var evidencePanel: some View {
        DietEvidencePanel(
            loadState: loadState,
            nutrition: todayNutrition
        )
    }

    private var mealList: some View {
        DietMealListPanel(
            loadState: loadState,
            meals: meals,
            onMealTap: onMealTap,
            onDeleteMeal: onDeleteMeal
        )
    }
}

private struct DietEvidencePanel: View {
    let loadState: DietLoadState
    let nutrition: MealNutritionEvidenceWindow?

    private var calText: String {
        guard let nutrition else { return "—" }
        switch nutrition.calories {
        case .noMeals:
            return "—"
        case .incomplete:
            return "未完整"
        case let .complete(value):
            return String(format: "%.0f kcal", value)
        }
    }

    private var proteinText: String {
        guard let totals = nutrition?.totals,
              let protein = MealNutritionProjection.validatedValue(totals.proteinG) else {
            return "—"
        }
        return String(format: "%.0f g", protein)
    }

    private var fatText: String {
        guard let totals = nutrition?.totals,
              let fat = MealNutritionProjection.validatedValue(totals.fatG) else {
            return "—"
        }
        return String(format: "%.0f g", fat)
    }

    private var carbText: String {
        guard let totals = nutrition?.totals,
              let carbs = MealNutritionProjection.validatedValue(totals.carbsG) else {
            return "—"
        }
        return String(format: "%.0f g", carbs)
    }

    private var statusHint: String {
        switch loadState {
        case .loading:
            return "读取中"
        case .failed:
            return "待重试"
        case .stale:
            return "上次读取"
        case .loaded:
            guard let nutrition else { return "未返回" }
            if nutrition.mealCount == 0 {
                return "今日空白"
            }
            return "有记录"
        }
    }

    var body: some View {
        Group {
            if loadState == .loading {
                VStack(alignment: .leading, spacing: 12) {
                    HMLoadingSkeleton(width: 128, height: 20)
                    HMLoadingSkeleton(height: 54)
                    HMLoadingSkeleton(height: 48)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("正在读取今日营养汇总")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 4) {
                        Text("今日营养汇总")
                            .font(.title3.weight(.semibold))
                        Spacer(minLength: 4)
                        HMEvidenceTag(
                            tone: loadState == .failed ? .actionRequired : .comparison,
                            text: statusHint,
                            systemImage: "chart.bar.doc.horizontal"
                        )
                        .font(.footnote)
                    }

                    HStack(spacing: 0) {
                        DietMetricCell(label: "热量", value: calText)
                        Divider().overlay(HMColors.separator)
                        DietMetricCell(label: "蛋白", value: proteinText)
                        Divider().overlay(HMColors.separator)
                        DietMetricCell(label: "脂肪", value: fatText)
                        Divider().overlay(HMColors.separator)
                        DietMetricCell(label: "碳水", value: carbText)
                    }

                    HMInformationRow(
                        systemImage: "list.bullet.rectangle",
                        tone: loadState == .failed ? .actionRequired : .comparison,
                        title: "今日餐次",
                        detail: loadState.hasUsableContent && (nutrition?.mealCount ?? 0) == 0
                            ? "等待你主动保存第一餐"
                            : (loadState == .failed ? "尚未取得餐次快照" : "支持继续补录并编辑")
                    )

                    if let totals = nutrition?.totals,
                       [totals.caloriesKcal, totals.proteinG, totals.fatG, totals.carbsG]
                        .contains(where: { $0 == nil }) {
                        HMEvidenceTag(
                            tone: .estimate,
                            text: "部分营养字段缺失，未知值显示“—”。",
                            systemImage: "exclamationmark.triangle"
                        )
                    }
                }
            }
        }
        .padding(16)
        .hmSurface(cornerRadius: 18)
    }
}

private struct DietMetricCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

private struct DietMealListPanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let loadState: DietLoadState
    let meals: [MealRecord]
    let onMealTap: (MealRecord) -> Void
    let onDeleteMeal: (MealRecord) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("近期餐次")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                if loadState.hasUsableContent, !meals.isEmpty {
                    Text("共 \(meals.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            switch loadState {
            case .loading:
                VStack(spacing: 10) {
                    HMLoadingSkeleton(height: 44)
                    Divider().overlay(HMColors.separator)
                    HMLoadingSkeleton(height: 44)
                    Divider().overlay(HMColors.separator)
                    HMLoadingSkeleton(height: 44)
                }
                .padding(.vertical, 10)

            case .failed:
                Text("餐次记录加载失败，请下拉重试")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)

            case .loaded, .stale:
                if meals.isEmpty {
                    HMEmptyState(
                        title: "暂无餐次",
                        message: "最近还没有保存的餐次。可以从上方记录一次，或复用历史餐次创建新草稿。",
                        icon: "fork.knife",
                        tone: .neutral,
                        primaryActionTitle: nil,
                        secondaryActionTitle: nil
                    )
                } else {
                    List {
                        ForEach(meals) { meal in
                            Button {
                                onMealTap(meal)
                            } label: {
                                MealRow(meal: meal)
                                    .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .accessibilityIdentifier("meal-row-\(meal.id ?? -1)")
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await onDeleteMeal(meal) }
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .frame(height: listHeight)
                }
            }
        }
        .padding(14)
        .hmSurface(cornerRadius: 18)
    }

    private var listHeight: CGFloat {
        let estimatedRowHeight: CGFloat = dynamicTypeSize.isAccessibilitySize ? 156 : 86
        return max(estimatedRowHeight, CGFloat(meals.count) * estimatedRowHeight)
    }
}

private struct MealRow: View {
    let meal: MealRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let firstPath = meal.photoPaths.first,
               let img = MealPhotoStore.shared.loadThumbnail(path: firstPath) {
                ZStack(alignment: .bottomTrailing) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    if meal.photoPaths.count > 1 {
                        Text("+\(meal.photoPaths.count - 1)")
                            .font(.caption2.bold().monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(3)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(meal.mealType.label).font(.body.bold())
                    Spacer()
                    Text(dateLabel).font(.footnote).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Text(nutritionText(meal.caloriesKcal, prefix: "", suffix: " kcal"))
                    Text(nutritionText(meal.proteinG, prefix: "P ", suffix: "g"))
                    Text(nutritionText(meal.fatG, prefix: "F ", suffix: "g"))
                    Text(nutritionText(meal.carbsG, prefix: "C ", suffix: "g"))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                if let notes = meal.notes, !notes.isEmpty {
                    Text(notes).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var dateLabel: String {
        AppDateFormats.shortDateTime.string(from: Date(timeIntervalSince1970: TimeInterval(meal.eatenAt)))
    }

    private func nutritionText(_ value: Double?, prefix: String, suffix: String) -> String {
        guard let value = MealNutritionProjection.validatedValue(value) else {
            return "\(prefix)—"
        }
        return "\(prefix)\(mealNutritionText(value))\(suffix)"
    }
}

struct MealEditView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    private let editing: MealRecord?

    @State private var draft: MealEditorDraft
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var showingCamera: Bool = false
    @State private var showingPhotoPicker: Bool = false
    @State private var nutritionEstimate: MealNutritionAnalyzer.Estimate?
    @State private var isAnalyzingNutrition: Bool = false
    @State private var isImportingPhotos: Bool = false
    @State private var isSaving: Bool = false
    @State private var nutritionError: String?
    @State private var saveError: String?
    /// Per-input progress shown next to the AI button, e.g. "分析中：照片 2 / 3".
    @State private var analysisProgress: String?
    /// Inputs already analyzed in this session. Keyed by a stable id (`"text:<hash>"` or
    /// `"photo:<savedPath>"`) so the AI-button only re-runs work for *new* inputs and never
    /// double-counts. Re-typing the description or re-adding a photo invalidates the key.
    @State private var analyzedInputKeys: Set<String> = []
    /// Free-form text the user types to describe the meal (e.g. "十个猪肉芹菜水饺").
    /// Estimated via the text LLM, independent of any photo.
    @State private var foodDescription: String = ""

    init(editing: MealRecord? = nil) {
        self.editing = editing
        _draft = State(initialValue: MealEditorDraft(meal: editing))
    }

    init(copying copyDraft: MealStore.CopyDraft) {
        self.editing = nil
        _draft = State(initialValue: MealEditorDraft(copyDraft: copyDraft))
    }

    private var saveDisabled: Bool {
        isBusy || !draft.canSave
    }

    private var isBusy: Bool {
        isSaving || isAnalyzingNutrition || isImportingPhotos || draft.loadState == .loading
    }

    private var totalCaloriesText: String {
        draft.parentDisplayLabel(for: draft.itemTotals?.caloriesKcal)
    }

    private var totalProteinText: String {
        draft.parentDisplayLabel(for: draft.itemTotals?.proteinG)
    }

    private var totalFatText: String {
        draft.parentDisplayLabel(for: draft.itemTotals?.fatG)
    }

    private var totalCarbsText: String {
        draft.parentDisplayLabel(for: draft.itemTotals?.carbsG)
    }

    private var shouldBlockInteractiveDismiss: Bool {
        isBusy || draft.hasUnsubmittedSessionPhotos
    }

    private var draftError: String? {
        if case let .failed(message) = draft.loadState {
            return message
        }
        return saveError
    }

    var body: some View {
        NavigationStack {
            Form {
                if draft.loadState == .loading {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在加载餐次…")
                        }
                        .accessibilityIdentifier("meal-edit-loading")
                    }
                } else if isSaving {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在保存餐次…")
                        }
                        .accessibilityIdentifier("meal-edit-saving")
                    }
                }

                Section("餐次与时间") {
                    Picker("餐次", selection: $draft.mealType) {
                        ForEach(MealRecord.MealType.allCases, id: \.self) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    DatePicker("时间", selection: $draft.eatenAt)
                }
                Section {
                    photoCarousel
                } header: {
                    Text("照片（可加多张）")
                } footer: {
                    Text("每张菜分别拍摄更准。文字描述和每张照片会一起提交 AI 估算。")
                }

                Section {
                    TextField(
                        "用文字描述这餐，如「十个猪肉芹菜水饺」「麦香鱼汉堡不要酱」",
                        text: $foodDescription,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    .accessibilityIdentifier("meal-edit-description")
                } header: {
                    Text("文字描述")
                }

                aiEstimateSection

                nutritionSection

                Section {
                    if draft.isManualSummaryMode {
                        LabeledTextField(
                            label: "热量 kcal",
                            text: $draft.caloriesText,
                            keyboard: .decimalPad,
                            accessibilityIdentifier: "meal-edit-calories"
                        )
                        LabeledTextField(
                            label: "蛋白质 g",
                            text: $draft.proteinText,
                            keyboard: .decimalPad,
                            accessibilityIdentifier: "meal-edit-protein"
                        )
                        LabeledTextField(
                            label: "脂肪 g",
                            text: $draft.fatText,
                            keyboard: .decimalPad,
                            accessibilityIdentifier: "meal-edit-fat"
                        )
                        LabeledTextField(
                            label: "碳水 g",
                            text: $draft.carbsText,
                            keyboard: .decimalPad,
                            accessibilityIdentifier: "meal-edit-carbs"
                        )
                    } else {
                        ReadonlyNutritionSummaryRow(label: "热量 kcal", value: totalCaloriesText)
                        ReadonlyNutritionSummaryRow(label: "蛋白质 g", value: totalProteinText)
                        ReadonlyNutritionSummaryRow(label: "脂肪 g", value: totalFatText)
                        ReadonlyNutritionSummaryRow(label: "碳水 g", value: totalCarbsText)
                    }
                } header: {
                    Text("营养（可选）")
                } footer: {
                    if !draft.isManualSummaryMode {
                        Text("汇总由分项保守计算：任一分项的某项营养未知时，该项合计显示为“—”。")
                    }
                }

                Section("备注") {
                    TextField("备注", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("meal-edit-notes")
                }

            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let error = draftError {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(HMColors.actionRequired)
                            .accessibilityHidden(true)
                        Text(error)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("meal-edit-error")
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(HMColors.surface)
                    .overlay(alignment: .top) {
                        Divider().overlay(HMColors.separator)
                    }
                }
            }
            .disabled(!draft.canSave || isSaving)
            .navigationTitle(editing == nil ? "添加餐次" : "编辑餐次")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        cancelEditing()
                    }
                    .disabled(isBusy)
                    .accessibilityIdentifier("meal-edit-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard !isBusy else { return }
                        saveError = nil
                        isSaving = true
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("正在保存")
                        } else {
                            Text("保存")
                        }
                    }
                    .disabled(saveDisabled)
                    .tint(HMColors.primaryAction)
                    .accessibilityIdentifier("meal-edit-save")
                }
            }
            .interactiveDismissDisabled(shouldBlockInteractiveDismiss)
            .onChange(of: draft.nutritionItems) { _, _ in
                draft.reconcileTotalsFromItems()
            }
            .onChange(of: pickedPhotos) { _, newItems in
                guard !newItems.isEmpty else { return }
                Task { await loadPickedBatch(newItems) }
            }
            .photosPicker(
                isPresented: $showingPhotoPicker,
                selection: $pickedPhotos,
                maxSelectionCount: 8,
                matching: .images,
                photoLibrary: .shared()
            )
            .task {
                await loadExistingMealIfNeeded()
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraPicker(
                    onImage: { img in
                        showingCamera = false
                        ingestCapturedImage(img)
                    },
                    onCancel: {
                        showingCamera = false
                    }
                )
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Photo carousel + AI estimate section

    private var photoCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(draft.photoDrafts.enumerated()), id: \.offset) { index, photo in
                    photoThumb(photo: photo, index: index)
                }
                addPhotoTile
            }
            .padding(.vertical, 4)
        }
    }

    private func photoThumb(photo: MealEditorDraft.MealPhotoDraft, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = photo.image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.quaternary)
                        .overlay {
                            VStack(spacing: 4) {
                                Image(systemName: "photo")
                                    .font(.title2)
                                Text("占位")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Button {
                removePhoto(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .padding(4)
            .accessibilityLabel("移除这张照片")
            .disabled(isBusy)
        }
    }

    private var addPhotoTile: some View {
        Menu {
            if CameraPicker.isCameraAvailable {
                Button {
                    showingCamera = true
                } label: {
                    Label("拍照", systemImage: "camera.fill")
                }
            }
            Button {
                showingPhotoPicker = true
            } label: {
                Label("从相册选择…", systemImage: "photo.on.rectangle")
            }
        } label: {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(width: 96, height: 96)
                .overlay(
                    VStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.title2.weight(.semibold))
                        Text(draft.photoDrafts.isEmpty ? "添加" : "再添加")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                )
        }
        .accessibilityLabel("添加照片")
        .disabled(isBusy)
    }

    private func removePhoto(at index: Int) {
        guard draft.photoDrafts.indices.contains(index) else { return }
        guard let removed = draft.removePhoto(at: index) else { return }
        analyzedInputKeys.remove(photoKey(for: removed.path))
        if removed.isSessionCreated {
            MealPhotoStore.shared.removeIfManaged(path: removed.path)
        }
    }

    /// Single "AI 估算营养" trigger + status.
    @ViewBuilder
    private var aiEstimateSection: some View {
        Section {
            let pending = pendingInputCount
            Button {
                Task { await runAIEstimate() }
            } label: {
                Group {
                    if isAnalyzingNutrition {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(analysisProgress ?? "AI 估算中…")
                        }
                    } else if pending > 0 {
                        Label("AI 估算营养（\(pending) 项待处理）", systemImage: "sparkles")
                    } else {
                        Label("AI 估算营养", systemImage: "sparkles")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(HMColors.estimate)
            .disabled(isBusy || pending == 0 || !canCallAnyModel)
            .accessibilityIdentifier("meal-edit-ai-estimate")

            if !canCallAnyModel {
                Text("未配置 AI 模型。前往「设置 → AI 摘要」配置文本或图像模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !foodDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !LLMConfig.isConfigured {
                Text("文字描述需要配置文本模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !draft.photoDrafts.isEmpty, !LLMConfig.isVisionConfigured {
                Text("照片估算需要配置视觉模型（如 glm-4v-flash）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let nutritionError {
                HMEditorCallout(
                    title: "部分输入未完成",
                    message: "已成功的估算会保留在下方；再次估算只处理尚未完成的文字或照片。",
                    tone: .actionRequired,
                    systemImage: "exclamationmark.triangle.fill",
                    detail: nutritionError,
                    accessibilityIdentifier: "meal-edit-ai-error"
                )
            }
        } header: {
            Text("AI 估算")
        } footer: {
            Text("仅在你点击后，文字与所选照片才会发送到已配置的模型服务。返回结果会合并到营养分项，但不自动升级为确认事实。")
        }
    }

    private var canCallAnyModel: Bool {
        guard LLMConfig.enabled else { return false }
        let hasText = !foodDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPhotoWithImage = draft.photoDrafts.contains(where: { $0.image != nil })
        return (hasText && LLMConfig.isConfigured) || (hasPhotoWithImage && LLMConfig.isVisionConfigured)
    }

    private var pendingInputCount: Int {
        var n = 0
        if !textInputKey().isEmpty, !analyzedInputKeys.contains(textInputKey()) { n += 1 }
        for photo in draft.photoDrafts {
            let key = photoKey(for: photo.path)
            if photo.image != nil && !analyzedInputKeys.contains(key) {
                n += 1
            }
        }
        return n
    }

    private func textInputKey() -> String {
        let trimmed = foodDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : "text:\(trimmed.hashValue)"
    }

    private func photoKey(for path: String) -> String { "photo:\(path)" }

    // MARK: - Concurrent analysis pipeline

    private func runAIEstimate() async {
        guard pendingInputCount > 0, canCallAnyModel else { return }

        var jobs: [AnalysisJob] = []
        let textTrimmed = foodDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !textTrimmed.isEmpty, !analyzedInputKeys.contains(textInputKey()) {
            jobs.append(
                AnalysisJob(
                    kind: .text(textTrimmed),
                    key: textInputKey(),
                    label: "文字描述",
                    analysisModelName: LLMConfig.textModel.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }

        for (index, photo) in draft.photoDrafts.enumerated() {
            guard let image = photo.image else { continue }
            let key = photoKey(for: photo.path)
            if analyzedInputKeys.contains(key) { continue }
            jobs.append(
                AnalysisJob(
                    kind: .image(image),
                    key: key,
                    label: "照片 \(index + 1)",
                    analysisModelName: LLMConfig.visionModel.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }

        guard !jobs.isEmpty else { return }

        let total = jobs.count
        await MainActor.run {
            isAnalyzingNutrition = true
            nutritionError = nil
            analysisProgress = "AI 估算中…（0/\(total)）"
        }
        defer {
            Task { @MainActor in
                isAnalyzingNutrition = false
                analysisProgress = nil
            }
        }

        var results = [Int: Result<MealNutritionAnalyzer.Estimate, Error>](minimumCapacity: total)
        var done = 0
        await withTaskGroup(of: (Int, Result<MealNutritionAnalyzer.Estimate, Error>).self) { group in
            let cap = min(2, total)
            var next = 0
            func submit() {
                let i = next
                next += 1
                let job = jobs[i]
                group.addTask { (i, await Self.analyzeNutritionJob(job)) }
            }
            while next < cap { submit() }
            for await (i, result) in group {
                results[i] = result
                done += 1
                await MainActor.run {
                    analysisProgress = "AI 估算中…（\(done)/\(total)）"
                }
                if next < total { submit() }
            }
        }

        var addedItems: [MealItemDraft] = []
        var errors: [String] = []
        var analyzedKeys: [String] = []
        var lastEstimate: MealNutritionAnalyzer.Estimate?

        for i in 0..<total {
            let job = jobs[i]
            switch results[i] {
            case .success(let estimate):
                if estimate.items.isEmpty {
                    let why = (estimate.note?.isEmpty == false) ? "（\(estimate.note!)）" : ""
                    errors.append("\(job.label)未识别出食物\(why)")
                } else {
                    let converted = estimate.items.map {
                        MealItemDraft.fromAiEstimate(
                            item: $0,
                            batchConfidence: estimate.confidence,
                            modelName: job.analysisModelName
                        )
                    }
                    addedItems.append(contentsOf: converted)
                    analyzedKeys.append(job.key)
                    lastEstimate = estimate
                }
            case .failure(let err):
                errors.append("\(job.label)：\(err.localizedDescription)")
                AppLogger.shared.error("AI estimate failed for \(job.label): \(err.localizedDescription)")
            case .none:
                break
            }
        }

        await MainActor.run {
            nutritionEstimate = lastEstimate
            if !addedItems.isEmpty {
                appendDedupedItems(addedItems)
                analyzedKeys.forEach { analyzedInputKeys.insert($0) }
                draft.reconcileTotalsFromItems()
                if draft.notes.isEmpty, !textTrimmed.isEmpty, analyzedKeys.contains(textInputKey()) {
                    draft.notes = textTrimmed
                }
            }
            nutritionError = errors.isEmpty ? nil : errors.joined(separator: ", ")
        }
    }

    private static func analyzeNutritionJob(_ job: AnalysisJob) async -> Result<MealNutritionAnalyzer.Estimate, Error> {
        do {
            switch job.kind {
            case .text(let desc): return .success(try await MealNutritionAnalyzer.analyze(text: desc))
            case .image(let image): return .success(try await MealNutritionAnalyzer.analyze(image: image))
            }
        } catch {
            return .failure(error)
        }
    }

    private func appendDedupedItems(_ newItems: [MealItemDraft]) {
        draft.nutritionItems.append(contentsOf: MealItemDraft.deduped(newItems, against: draft.nutritionItems))
    }

    private func ingestCapturedImage(_ image: UIImage) {
        guard let saved = MealPhotoStore.shared.save(image: image) else { return }
        draft.photoDrafts.append(MealEditorDraft.MealPhotoDraft(path: saved, image: image, isSessionCreated: true))
        analyzedInputKeys.remove(photoKey(for: saved))
    }

    private func loadPickedBatch(_ items: [PhotosPickerItem]) async {
        isImportingPhotos = true
        defer { isImportingPhotos = false }

        var loaded: [(UIImage, String)] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let saved = MealPhotoStore.shared.save(image: image) else {
                continue
            }
            loaded.append((image, saved))
        }
        guard !loaded.isEmpty else {
            pickedPhotos = []
            return
        }

        await MainActor.run {
            for (image, path) in loaded {
                draft.photoDrafts.append(MealEditorDraft.MealPhotoDraft(path: path, image: image, isSessionCreated: true))
                analyzedInputKeys.remove(photoKey(for: path))
            }
            pickedPhotos = []
        }
    }

    @ViewBuilder
    private var nutritionSection: some View {
        Section {
            if isAnalyzingNutrition {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(analysisProgress ?? "AI 估算中…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(Array(draft.nutritionItems.enumerated()), id: \.1.id) { index, item in
                let binding = Binding(
                    get: { draft.nutritionItems[index] },
                    set: { draft.nutritionItems[index] = $0 }
                )
                nutritionItemRow(binding, index: index)
            }
            .onDelete { offsets in
                draft.nutritionItems.remove(atOffsets: offsets)
                draft.reconcileTotalsFromItems()
            }

            Button {
                draft.nutritionItems.append(.manualEmpty())
                draft.reconcileTotalsFromItems()
            } label: {
                Label("添加菜品", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("meal-edit-add-item")
            .disabled(isBusy)

            nutritionTotalsRow

            if let note = nutritionEstimate?.note, !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }

            if let error = nutritionError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("估算结果")
        }
    }

    @ViewBuilder
    private func nutritionItemRow(_ item: Binding<MealItemDraft>, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "fork.knife.circle.fill").foregroundStyle(.tint)
                TextField("菜名", text: item.name)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .accessibilityIdentifier("meal-item-name-\(index)")
            }
            HStack(spacing: 8) {
                TextField("克", text: item.gramsText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 70)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("meal-item-grams-\(index)")
                Text("g").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text(formatMacro(item.wrappedValue.calories))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tint)
            }
            HStack(spacing: 10) {
                macroBadge("P", grams: item.wrappedValue.protein)
                macroBadge("F", grams: item.wrappedValue.fat)
                macroBadge("C", grams: item.wrappedValue.carbs)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            MealItemEvidenceView(item: item.wrappedValue, index: index)
            if !item.wrappedValue.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CommonGramSuggestionsRow(item: item, index: index)
            }
        }
        .padding(.vertical, 2)
        .onChange(of: item.wrappedValue) { _, _ in
            draft.reconcileTotalsFromItems()
        }
    }

    private func macroBadge(_ label: String, grams: Double?) -> some View {
        HStack(spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(formatMacro(grams))
        }
    }

    @ViewBuilder
    private var nutritionTotalsRow: some View {
        let totals = draft.itemTotals
        let totalK = totals?.caloriesKcal
        let totalP = totals?.proteinG
        let totalF = totals?.fatG
        let totalC = totals?.carbsG

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("合计").font(.body.bold())
                Spacer()
                Text(formatMacro(totalK))
                    .font(.body.bold().monospacedDigit())
                    .foregroundStyle(.tint)
                Text("kcal")
                    .font(.body)
            }
            Text("P \(formatMacro(totalP))g · F \(formatMacro(totalF))g · C \(formatMacro(totalC))g")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func formatMacro(_ value: Double?) -> String {
        guard let value else { return "—" }
        return mealNutritionText(value)
    }

    private func save() async {
        guard draft.canSave else {
            await MainActor.run {
                saveError = "未进入可编辑状态"
                isSaving = false
            }
            return
        }

        do {
            let record = try draft.makeMealRecord()
            let saved = try await environment.mealPersistenceCoordinator.save(
                meal: record,
                drafts: draft.nutritionItems,
                originalPhotoPaths: draft.originalPhotoPaths
            )
            await MainActor.run {
                draft.apply(snapshot: saved, loadImage: MealPhotoStore.shared.loadImage(path:))
                environment.notifyLocalDataChanged()
                isSaving = false
                saveError = nil
                dismiss()
            }
        } catch {
            await MainActor.run {
                saveError = MealEditorDraft.userFacingSaveError(error)
                isSaving = false
            }
        }
    }

    private func loadExistingMealIfNeeded() async {
        guard case .loading = draft.loadState, let editing, let id = editing.id else {
            return
        }
        do {
            guard let snapshot = try await environment.mealStore.load(id: id) else {
                await MainActor.run {
                    draft.markLoadFailure("未找到该餐次（已删除）：\(id)")
                }
                return
            }
            await MainActor.run {
                draft.apply(snapshot: snapshot, loadImage: MealPhotoStore.shared.loadImage(path:))
            }
        } catch {
            await MainActor.run {
                draft.markLoadFailure("加载餐次失败：\(error.localizedDescription)")
            }
        }
    }

    private func cancelEditing() {
        guard !isBusy else { return }
        for path in draft.sessionCreatedPhotoPaths {
            MealPhotoStore.shared.removeIfManaged(path: path)
        }
        dismiss()
    }
}

private struct ReadonlyNutritionSummaryRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

struct LabeledTextField: View {
    let label: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var accessibilityIdentifier: String = ""

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", text: $text)
                .accessibilityIdentifier(accessibilityIdentifier)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
        }
    }
}

/// One unit of AI nutrition work for the meal editor's concurrent estimate pass.
/// `@unchecked Sendable`: the only non-Sendable field is `UIImage`, which we treat as
/// read-only (never mutated) while it's handed to the analysis task.
private struct AnalysisJob: @unchecked Sendable {
    enum Kind {
        case text(String)
        case image(UIImage)
    }
    let kind: Kind
    let key: String
    let label: String
    let analysisModelName: String
}

private enum DietPreviewFixtures {
    static let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        return calendar.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 8, minute: 12)) ?? Date()
    }()

    static let todayMeal: MealRecord = {
        MealRecord(
            id: 1,
            mealType: .breakfast,
            eatenAt: Int64(now.timeIntervalSince1970),
            caloriesKcal: 540,
            proteinG: 32,
            fatG: 14,
            carbsG: 45,
            photoPath: nil,
            notes: "示例餐食",
            createdAt: Int64(now.timeIntervalSince1970),
            hkSyncId: nil
        )
    }()

    static let loadedNutrition: MealNutritionEvidenceWindow = {
        MealNutritionEvidenceWindow(
            mealCount: 1,
            totals: MealNutritionTotals(
                caloriesKcal: 540,
                proteinG: 32,
                fatG: 14,
                carbsG: 45
            ),
            calories: .complete(540),
            days: []
        )
    }()

    static let emptyNutrition: MealNutritionEvidenceWindow = {
        MealNutritionEvidenceWindow(
            mealCount: 0,
            totals: nil,
            calories: .noMeals,
            days: []
        )
    }()
}

#Preview("Diet loaded") {
    DietScreenContent(
        loadState: .loaded,
        meals: [DietPreviewFixtures.todayMeal],
        todayNutrition: DietPreviewFixtures.loadedNutrition,
        onAdd: {},
        onReuse: {},
        onMealTap: { _ in },
        onDeleteMeal: { _ in },
        onRetry: {}
    )
    .environment(\.locale, Locale(identifier: "zh_CN"))
}

#Preview("Diet loaded (Dark)") {
    DietScreenContent(
        loadState: .loaded,
        meals: [DietPreviewFixtures.todayMeal],
        todayNutrition: DietPreviewFixtures.loadedNutrition,
        onAdd: {},
        onReuse: {},
        onMealTap: { _ in },
        onDeleteMeal: { _ in },
        onRetry: {}
    )
    .environment(\.locale, Locale(identifier: "zh_CN"))
    .preferredColorScheme(.dark)
}

#Preview("Diet loaded (Accessibility Large)") {
    DietScreenContent(
        loadState: .loaded,
        meals: [DietPreviewFixtures.todayMeal],
        todayNutrition: DietPreviewFixtures.loadedNutrition,
        onAdd: {},
        onReuse: {},
        onMealTap: { _ in },
        onDeleteMeal: { _ in },
        onRetry: {}
    )
    .environment(\.locale, Locale(identifier: "zh_CN"))
    .environment(\.dynamicTypeSize, .accessibility2)
}

#Preview("Diet empty") {
    DietScreenContent(
        loadState: .loaded,
        meals: [],
        todayNutrition: DietPreviewFixtures.emptyNutrition,
        onAdd: {},
        onReuse: {},
        onMealTap: { _ in },
        onDeleteMeal: { _ in },
        onRetry: {}
    )
    .environment(\.locale, Locale(identifier: "zh_CN"))
}
