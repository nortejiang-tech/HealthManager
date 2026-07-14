import SwiftUI
import PhotosUI
import GRDB
import UIKit

private func mealNutritionText(_ value: Double) -> String {
    value == value.rounded() ? String(format: "%.0f", value) : String(value)
}

struct DietView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var meals: [MealRecord] = []
    @State private var activeSheet: DietSheetKind?
    @State private var todayTotals: Totals = .zero
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

    struct Totals: Equatable {
        var calories: Double
        var protein: Double
        var fat: Double
        var carbs: Double
        static let zero = Totals(calories: 0, protein: 0, fat: 0, carbs: 0)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("今日合计") {
                    LabeledContent("热量", value: String(format: "%.0f kcal", todayTotals.calories))
                    LabeledContent("蛋白质", value: String(format: "%.0f g", todayTotals.protein))
                    LabeledContent("脂肪", value: String(format: "%.0f g", todayTotals.fat))
                    LabeledContent("碳水", value: String(format: "%.0f g", todayTotals.carbs))
                }

                Section("近期餐次") {
                    if meals.isEmpty {
                        Text("尚无记录。点击右上 + 添加一次。").foregroundStyle(.secondary)
                    } else {
                        ForEach(meals) { meal in
                            Button { activeSheet = .edit(meal) } label: {
                                MealRow(meal: meal)
                            }
                            .accessibilityIdentifier("meal-row-\(meal.id ?? -1)")
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await delete(meal) }
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("饮食")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        activeSheet = .add
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("diet-add-meal")
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
        do {
            let (list, totals) = try await environment.database.asyncRead { db -> ([MealRecord], Totals) in
                let rows = try MealRecord
                    .order(Column("eaten_at").desc)
                    .limit(50)
                    .fetchAll(db)

                let calendar = Calendar.current
                let dayStart = calendar.startOfDay(for: Date())
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
                let s = Int64(dayStart.timeIntervalSince1970)
                let e = Int64(dayEnd.timeIntervalSince1970)
                let totalRow = try Row.fetchOne(db, sql: """
                    SELECT
                        COALESCE(SUM(calories_kcal), 0) AS cal,
                        COALESCE(SUM(protein_g), 0) AS pro,
                        COALESCE(SUM(fat_g), 0) AS fat,
                        COALESCE(SUM(carbs_g), 0) AS carb
                    FROM meal_records
                    WHERE eaten_at BETWEEN ? AND ?
                    """, arguments: [s, e])
                let totals = Totals(
                    calories: totalRow?["cal"] ?? 0,
                    protein: totalRow?["pro"] ?? 0,
                    fat: totalRow?["fat"] ?? 0,
                    carbs: totalRow?["carb"] ?? 0
                )
                return (rows, totals)
            }
            await MainActor.run {
                meals = list
                todayTotals = totals
            }
        } catch {
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
                    if let c = meal.caloriesKcal { Text("\(mealNutritionText(c)) kcal") }
                    if let p = meal.proteinG { Text("P \(mealNutritionText(p))g") }
                    if let f = meal.fatG { Text("F \(mealNutritionText(f))g") }
                    if let c = meal.carbsG { Text("C \(mealNutritionText(c))g") }
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

                Section("基本") {
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

                if let error = draftError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("meal-edit-error")
                }
            }
            .scrollDismissesKeyboard(.interactively)
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
            .disabled(isBusy || pending == 0 || !canCallAnyModel)

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
        } header: {
            Text("AI 估算")
        } footer: {
            Text("点按钮后会把文字描述与每张照片并行交给模型估算，结果合并到下方营养列表（自动去重同名菜品）。")
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

            if let conf = nutritionEstimate?.confidence {
                Text(confidenceLabel(conf))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

    private func confidenceLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "high": return "置信：高"
        case "medium": return "置信：中"
        case "low": return "置信：低"
        default: return "置信：\(raw)"
        }
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
