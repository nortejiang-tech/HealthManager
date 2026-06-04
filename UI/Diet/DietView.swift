import SwiftUI
import PhotosUI
import GRDB

struct DietView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var meals: [MealRecord] = []
    @State private var showingAdd: Bool = false
    @State private var editingMeal: MealRecord?
    @State private var todayTotals: Totals = .zero

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
                            Button { editingMeal = meal } label: {
                                MealRow(meal: meal)
                            }
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd, onDismiss: { Task { await refresh() } }) {
                MealEditView()
            }
            .sheet(item: $editingMeal, onDismiss: { Task { await refresh() } }) { meal in
                MealEditView(editing: meal)
            }
            .task { await refresh() }
            .refreshable { await refresh() }
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
        guard let id = meal.id else { return }
        do {
            try await environment.database.asyncWrite { db in
                _ = try MealRecord.deleteOne(db, key: id)
            }
            // Drop every on-disk photo for this meal.
            for path in meal.photoPaths {
                MealPhotoStore.shared.removeIfManaged(path: path)
            }
            // Remove the nutrition samples we wrote to Apple Health for this meal.
            if let syncId = meal.hkSyncId {
                await environment.healthKitManager.deleteNutritionSamples(syncId: syncId)
            }
            environment.notifyLocalDataChanged()
            await refresh()
        } catch {
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
                    if let c = meal.caloriesKcal { Text("\(Int(c)) kcal") }
                    if let p = meal.proteinG { Text("P \(Int(p))g") }
                    if let f = meal.fatG { Text("F \(Int(f))g") }
                    if let c = meal.carbsG { Text("C \(Int(c))g") }
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

    @State private var mealType: MealRecord.MealType
    @State private var eatenAt: Date
    @State private var calories: String
    @State private var protein: String
    @State private var fat: String
    @State private var carbs: String
    @State private var notes: String
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var previewImages: [UIImage] = []
    @State private var savedPhotoPaths: [String] = []
    @State private var originalPhotoPaths: [String] = []
    @State private var showingCamera: Bool = false
    @State private var showingPhotoPicker: Bool = false
    @State private var nutritionEstimate: MealNutritionAnalyzer.Estimate?
    @State private var isAnalyzingNutrition: Bool = false
    @State private var nutritionError: String?
    /// Per-input progress shown next to the AI button, e.g. "分析中：照片 2 / 3".
    @State private var analysisProgress: String?
    /// Inputs already analyzed in this session. Keyed by a stable id (`"text:<hash>"` or
    /// `"photo:<savedPath>"`) so the AI-button only re-runs work for *new* inputs and never
    /// double-counts. Re-typing the description or re-adding a photo invalidates the key.
    @State private var analyzedInputKeys: Set<String> = []
    /// Free-form text the user types to describe the meal (e.g. "十个猪肉芹菜水饺").
    /// Estimated via the text LLM, independent of any photo.
    @State private var foodDescription: String = ""
    /// Editable copy of `nutritionEstimate.items`. Each row shows name + grams; macros
    /// scale proportionally to the per-item baseline when the user edits grams. Totals
    /// auto-sync into the caloriesKcal/proteinG/fatG/carbsG fields below.
    @State private var nutritionItems: [EditableNutritionItem] = []

    init(editing: MealRecord? = nil) {
        self.editing = editing
        if let m = editing {
            _mealType = State(initialValue: m.mealType)
            _eatenAt = State(initialValue: Date(timeIntervalSince1970: TimeInterval(m.eatenAt)))
            _calories = State(initialValue: m.caloriesKcal.map { String(Int($0)) } ?? "")
            _protein = State(initialValue: m.proteinG.map { String(Int($0)) } ?? "")
            _fat = State(initialValue: m.fatG.map { String(Int($0)) } ?? "")
            _carbs = State(initialValue: m.carbsG.map { String(Int($0)) } ?? "")
            _notes = State(initialValue: m.notes ?? "")
            let paths = m.photoPaths
            _savedPhotoPaths = State(initialValue: paths)
            _originalPhotoPaths = State(initialValue: paths)
        } else {
            _mealType = State(initialValue: MealRecord.MealType.suggested())
            _eatenAt = State(initialValue: Date())
            _calories = State(initialValue: "")
            _protein = State(initialValue: "")
            _fat = State(initialValue: "")
            _carbs = State(initialValue: "")
            _notes = State(initialValue: "")
            _savedPhotoPaths = State(initialValue: [])
            _originalPhotoPaths = State(initialValue: [])
        }
    }

    private var isEditing: Bool { editing?.id != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本") {
                    Picker("餐次", selection: $mealType) {
                        ForEach(MealRecord.MealType.allCases, id: \.self) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    DatePicker("时间", selection: $eatenAt)
                }
                Section {
                    photoCarousel
                } header: {
                    Text("照片（可加多张）")
                } footer: {
                    Text("每张菜分别拍摄会更准。所有照片连同下方的文字描述会一起按 AI 估算营养。")
                }

                Section {
                    TextField("用文字描述这餐，如「十个猪肉芹菜水饺」「麦香鱼汉堡不要酱」",
                              text: $foodDescription, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("文字描述")
                }

                aiEstimateSection

                if !nutritionItems.isEmpty || isAnalyzingNutrition || nutritionError != nil {
                    nutritionSection
                }
                Section("营养（可选）") {
                    LabeledTextField(label: "热量 kcal", text: $calories, keyboard: .decimalPad)
                    LabeledTextField(label: "蛋白质 g", text: $protein, keyboard: .decimalPad)
                    LabeledTextField(label: "脂肪 g", text: $fat, keyboard: .decimalPad)
                    LabeledTextField(label: "碳水 g", text: $carbs, keyboard: .decimalPad)
                }
                Section("备注") {
                    TextField("备注", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle(isEditing ? "编辑餐次" : "添加餐次")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            await save()
                            dismiss()
                        }
                    }
                }
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
                // Load the meal's original photos for editor preview.
                if previewImages.isEmpty, !originalPhotoPaths.isEmpty {
                    let loaded = originalPhotoPaths.compactMap { MealPhotoStore.shared.loadImage(path: $0) }
                    previewImages = loaded
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraPicker(
                    onImage: { img in
                        showingCamera = false
                        ingestCapturedImage(img)
                    },
                    onCancel: { showingCamera = false }
                )
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Photo carousel + AI estimate section

    /// Horizontal thumbnail strip + a trailing "+" tile for adding more photos. Each
    /// thumbnail has its own delete overlay. Tap "+" to choose camera or photo library.
    private var photoCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(previewImages.enumerated()), id: \.offset) { idx, img in
                    photoThumb(image: img, index: idx)
                }
                addPhotoTile
            }
            .padding(.vertical, 4)
        }
    }

    private func photoThumb(image: UIImage, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
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
                        Text(previewImages.isEmpty ? "添加" : "再添加")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                )
        }
        .accessibilityLabel("添加照片")
    }

    private func removePhoto(at index: Int) {
        guard previewImages.indices.contains(index) else { return }
        previewImages.remove(at: index)
        if savedPhotoPaths.indices.contains(index) {
            let path = savedPhotoPaths.remove(at: index)
            // Drop the file only if it was imported this session — don't yank a photo
            // that's still tied to the saved record on disk; save() will GC stale paths.
            if !originalPhotoPaths.contains(path) {
                MealPhotoStore.shared.removeIfManaged(path: path)
            }
            analyzedInputKeys.remove(photoKey(for: path))
        }
    }

    /// Single "AI 估算营养" trigger + status. Shows how many inputs are still pending and
    /// surfaces per-input progress while a serial pass is running.
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
            .disabled(isAnalyzingNutrition || pending == 0 || !canCallAnyModel)

            if !canCallAnyModel {
                Text("未配置 AI 模型。前往「设置 → AI 摘要」配置文本或图像模型。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if foodDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                      !LLMConfig.isConfigured {
                Text("文字描述需要配置文本模型。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !previewImages.isEmpty, !LLMConfig.isVisionConfigured {
                Text("照片估算需要配置视觉模型（如 glm-4v-flash）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("AI 估算")
        } footer: {
            Text("点按钮后会按「文字 → 照片1 → 照片2…」依次调用模型，结果累计添加到下方营养列表。已估算过的输入不会被重复调用。")
        }
    }

    /// Inputs that haven't been pushed through the AI yet. Text counts as 1 if non-empty
    /// and changed since last analysis; each new/changed photo counts as 1.
    private var pendingInputCount: Int {
        var n = 0
        if !textInputKey().isEmpty, !analyzedInputKeys.contains(textInputKey()) { n += 1 }
        for path in savedPhotoPaths where !analyzedInputKeys.contains(photoKey(for: path)) {
            n += 1
        }
        return n
    }

    private var canCallAnyModel: Bool {
        guard LLMConfig.enabled else { return false }
        let hasText = !foodDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPhotos = !previewImages.isEmpty
        return (hasText && LLMConfig.isConfigured) || (hasPhotos && LLMConfig.isVisionConfigured)
    }

    private func textInputKey() -> String {
        let trimmed = foodDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : "text:\(trimmed.hashValue)"
    }

    private func photoKey(for path: String) -> String { "photo:\(path)" }

    // MARK: - Sequential analysis pipeline

    /// Drive the AI through every pending input one at a time. Each successful estimate
    /// appends its items to `nutritionItems`; per-input failures are collected and shown
    /// at the end so a single bad photo doesn't kill the whole batch.
    private func runAIEstimate() async {
        guard pendingInputCount > 0, canCallAnyModel else { return }

        // Build the work list in the order the user sees inputs (text first, then photos
        // in carousel order). Each tuple carries everything we need to call + key it.
        enum Job {
            case text(String, key: String)
            case image(UIImage, path: String, key: String)
            var displayLabel: String {
                switch self {
                case .text: return "文字描述"
                case .image: return "照片"
                }
            }
        }
        var jobs: [Job] = []
        let textTrimmed = foodDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !textTrimmed.isEmpty, !analyzedInputKeys.contains(textInputKey()) {
            jobs.append(.text(textTrimmed, key: textInputKey()))
        }
        for (idx, img) in previewImages.enumerated() {
            guard savedPhotoPaths.indices.contains(idx) else { continue }
            let path = savedPhotoPaths[idx]
            let key = photoKey(for: path)
            if !analyzedInputKeys.contains(key) {
                jobs.append(.image(img, path: path, key: key))
            }
        }
        guard !jobs.isEmpty else { return }

        await MainActor.run {
            isAnalyzingNutrition = true
            nutritionError = nil
        }
        defer {
            Task { @MainActor in
                isAnalyzingNutrition = false
                analysisProgress = nil
            }
        }

        var addedItems: [EditableNutritionItem] = []
        var errors: [String] = []
        let total = jobs.count
        var photoCounter = 0

        for (idx, job) in jobs.enumerated() {
            // Update progress (1-based, with type-aware label).
            let progressText: String
            switch job {
            case .text:
                progressText = total == 1 ? "分析文字描述…" : "分析 \(idx + 1)/\(total)：文字描述"
            case .image:
                photoCounter += 1
                progressText = total == 1 ? "分析照片…" : "分析 \(idx + 1)/\(total)：照片 \(photoCounter)"
            }
            await MainActor.run { analysisProgress = progressText }

            do {
                let est: MealNutritionAnalyzer.Estimate
                switch job {
                case .text(let desc, _):
                    est = try await MealNutritionAnalyzer.analyze(text: desc)
                case .image(let img, _, _):
                    est = try await MealNutritionAnalyzer.analyze(image: img)
                }
                if est.items.isEmpty {
                    let why = (est.note?.isEmpty == false)
                        ? "（\(est.note!)）"
                        : ""
                    errors.append("\(job.displayLabel) 未识别出食物\(why)")
                } else {
                    addedItems.append(contentsOf: est.items.map(EditableNutritionItem.init(from:)))
                    await MainActor.run {
                        nutritionEstimate = est                 // keep latest non-empty for note/confidence
                        switch job {
                        case .text(_, let key): analyzedInputKeys.insert(key)
                        case .image(_, _, let key): analyzedInputKeys.insert(key)
                        }
                    }
                }
            } catch {
                errors.append("\(job.displayLabel)：\(error.localizedDescription)")
                AppLogger.shared.error("AI estimate failed for \(job.displayLabel): \(error.localizedDescription)")
            }
        }

        await MainActor.run {
            if !addedItems.isEmpty {
                nutritionItems.append(contentsOf: addedItems)
                syncTotalsFromItems()
                // Seed notes with the description on first successful text estimate.
                if notes.isEmpty, !textTrimmed.isEmpty,
                   jobs.contains(where: { if case .text = $0 { return true } else { return false } }) {
                    notes = textTrimmed
                }
            }
            nutritionError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        }
    }

    // MARK: - Photo intake (camera / picker)

    /// Append a newly-captured camera image to the carousel. We don't auto-analyze —
    /// estimation only fires from the explicit "AI 估算营养" button.
    private func ingestCapturedImage(_ img: UIImage) {
        guard let saved = MealPhotoStore.shared.save(image: img) else { return }
        previewImages.append(img)
        savedPhotoPaths.append(saved)
    }

    /// Same intake path for a batch of PhotosPickerItems (multi-select). Skips items that
    /// failed to load instead of failing the whole batch.
    private func loadPickedBatch(_ items: [PhotosPickerItem]) async {
        var loaded: [(UIImage, String)] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let img = UIImage(data: data),
                  let saved = MealPhotoStore.shared.save(image: img) else { continue }
            loaded.append((img, saved))
        }
        guard !loaded.isEmpty else { return }
        await MainActor.run {
            for (img, path) in loaded {
                previewImages.append(img)
                savedPhotoPaths.append(path)
            }
            pickedPhotos = []   // reset so a repeat selection re-fires onChange
        }
    }

    /// Push the sum of `nutritionItems`' (scaled) macros into the bottom calories/
    /// protein/fat/carbs text fields so the meal record reflects the items breakdown.
    /// Items are the source of truth whenever they're non-empty.
    private func syncTotalsFromItems() {
        guard !nutritionItems.isEmpty else { return }
        let totalK = nutritionItems.map(\.calories).reduce(0, +)
        let totalP = nutritionItems.map(\.protein).reduce(0, +)
        let totalF = nutritionItems.map(\.fat).reduce(0, +)
        let totalC = nutritionItems.map(\.carbs).reduce(0, +)
        calories = totalK > 0 ? String(Int(totalK.rounded())) : ""
        protein = totalP > 0 ? String(Int(totalP.rounded())) : ""
        fat = totalF > 0 ? String(Int(totalF.rounded())) : ""
        carbs = totalC > 0 ? String(Int(totalC.rounded())) : ""
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

            if !nutritionItems.isEmpty {
                ForEach($nutritionItems) { $item in
                    nutritionItemRow($item)
                }
                .onDelete { offsets in
                    nutritionItems.remove(atOffsets: offsets)
                    syncTotalsFromItems()
                }

                Button {
                    nutritionItems.append(.empty())
                } label: {
                    Label("添加菜品", systemImage: "plus.circle")
                }

                nutritionTotalsRow

                if let conf = nutritionEstimate?.confidence {
                    Text(confidenceLabel(conf))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let note = nutritionEstimate?.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }

                Text("修改克数会自动按比例换算各项营养，并合并填入下方字段。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let err = nutritionError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("估算结果")
        }
    }

    @ViewBuilder
    private func nutritionItemRow(_ item: Binding<EditableNutritionItem>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "fork.knife.circle.fill").foregroundStyle(.tint)
                TextField("菜名", text: item.name)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
            }
            HStack(spacing: 8) {
                TextField("克", text: item.gramsText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 70)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                Text("g").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(item.wrappedValue.calories.rounded())) kcal")
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
        }
        .padding(.vertical, 2)
        .onChange(of: item.wrappedValue) { _, _ in
            syncTotalsFromItems()
        }
    }

    private func macroBadge(_ label: String, grams: Double) -> some View {
        HStack(spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text("\(Int(grams.rounded()))g")
        }
    }

    @ViewBuilder
    private var nutritionTotalsRow: some View {
        let totalK = nutritionItems.map(\.calories).reduce(0, +)
        let totalP = nutritionItems.map(\.protein).reduce(0, +)
        let totalF = nutritionItems.map(\.fat).reduce(0, +)
        let totalC = nutritionItems.map(\.carbs).reduce(0, +)
        HStack {
            Text("合计").font(.body.bold())
            Spacer()
            Text("\(Int(totalK.rounded())) kcal")
                .font(.body.bold().monospacedDigit())
                .foregroundStyle(.tint)
        }
        Text("P \(Int(totalP.rounded()))g · F \(Int(totalF.rounded()))g · C \(Int(totalC.rounded()))g")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
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
        let createdAt = editing?.createdAt ?? Int64(Date().timeIntervalSince1970)
        var record = MealRecord(
            id: editing?.id,
            mealType: mealType,
            eatenAt: Int64(eatenAt.timeIntervalSince1970),
            caloriesKcal: Double(calories),
            proteinG: Double(protein),
            fatG: Double(fat),
            carbsG: Double(carbs),
            photoPath: nil,
            notes: notes.isEmpty ? nil : notes,
            createdAt: createdAt,
            hkSyncId: editing?.hkSyncId
        )
        record.photoPaths = savedPhotoPaths  // CSV-encoded into photo_path
        do {
            let savedId: Int64? = try await environment.database.asyncWrite { db -> Int64? in
                var r = record
                if r.id == nil {
                    try r.insert(db)
                } else {
                    try r.update(db)
                }
                return r.id
            }
            // GC any originally-saved photo that the user removed in this edit. Run after
            // the DB write succeeds so a failure can't strand the record pointing at deleted
            // files. New photos added but later removed in-session were already GC'd in
            // `removePhoto(at:)`.
            let stillKept = Set(savedPhotoPaths)
            for old in originalPhotoPaths where !stillKept.contains(old) {
                MealPhotoStore.shared.removeIfManaged(path: old)
            }
            environment.notifyLocalDataChanged()
            await syncNutritionToHealth(mealId: savedId ?? record.id, record: record)
        } catch {
            AppLogger.shared.error("Meal save failed: \(error.localizedDescription)")
        }
    }

    /// Best-effort write of this meal's macros to Apple Health, then persist the returned
    /// sync id so future edits/deletes update the same Health samples. Never blocks saving.
    private func syncNutritionToHealth(mealId: Int64?, record: MealRecord) async {
        let mealName = record.notes ?? mealType.label
        // Deterministic per-meal id (`meal-<rowid>`) keeps the write idempotent: if the
        // hk_sync_id persistence below fails, the next sync's catch-up re-targets the same
        // Health samples (delete-then-write) instead of creating a duplicate.
        let syncId = record.hkSyncId ?? mealId.map { "meal-\($0)" }
        let newSyncId = await environment.healthKitManager.syncMealNutrition(
            eatenAt: record.eatenAt,
            calories: record.caloriesKcal,
            protein: record.proteinG,
            fat: record.fatG,
            carbs: record.carbsG,
            name: mealName,
            existingSyncId: syncId
        )
        guard let newSyncId, newSyncId != record.hkSyncId, let id = mealId else { return }
        do {
            try await environment.database.asyncWrite { db in
                try db.execute(sql: "UPDATE meal_records SET hk_sync_id = ? WHERE id = ?",
                               arguments: [newSyncId, id])
            }
        } catch {
            // Not fatal: deterministic id means the next catch-up re-syncs without duplicating.
            AppLogger.shared.error("Persist hk_sync_id failed (will re-sync safely): \(error.localizedDescription)")
        }
    }
}


struct LabeledTextField: View {
    let label: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", text: $text)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
        }
    }
}

/// One row in the AI-nutrition section. `gramsText` is what the user types; `baseline*`
/// is the model's original estimate against `baselineGrams`. Computed macros scale
/// linearly with the gramsText-to-baseline ratio so editing grams immediately reflects
/// in the totals. `baselineGrams == 0` (e.g. user added an empty row) → all macros 0.
struct EditableNutritionItem: Identifiable, Equatable {
    let id: UUID = UUID()
    var name: String
    var gramsText: String
    /// The grams reported by the model when this row was created. Source of truth for
    /// the scaling ratio. Never mutated after init.
    let baselineGrams: Double
    let baselineCalories: Double
    let baselineProtein: Double
    let baselineFat: Double
    let baselineCarbs: Double

    var grams: Double { Double(gramsText) ?? 0 }

    private var ratio: Double {
        guard baselineGrams > 0 else { return 0 }
        return grams / baselineGrams
    }

    var calories: Double { baselineCalories * ratio }
    var protein: Double { baselineProtein * ratio }
    var fat: Double { baselineFat * ratio }
    var carbs: Double { baselineCarbs * ratio }

    init(from item: MealNutritionAnalyzer.Item) {
        let g = item.grams ?? 100
        self.name = item.name
        self.gramsText = String(Int(g.rounded()))
        self.baselineGrams = g
        self.baselineCalories = item.calories_kcal ?? 0
        self.baselineProtein = item.protein_g ?? 0
        self.baselineFat = item.fat_g ?? 0
        self.baselineCarbs = item.carbs_g ?? 0
    }

    /// Empty row the user added by tapping "+ 添加菜品". No baseline macros — the user
    /// can fill the name + grams, then re-estimate to ask the LLM to populate macros.
    static func empty() -> EditableNutritionItem {
        var item = EditableNutritionItem(from: MealNutritionAnalyzer.Item(
            name: "", grams: 100,
            calories_kcal: 0, protein_g: 0, fat_g: 0, carbs_g: 0
        ))
        item.name = ""
        return item
    }
}
