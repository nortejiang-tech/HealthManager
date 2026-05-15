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
            // Drop the on-disk photo if it lives in our sandbox.
            if let path = meal.photoPath {
                MealPhotoStore.shared.removeIfManaged(path: path)
            }
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
            if let path = meal.photoPath, let img = MealPhotoStore.shared.loadThumbnail(path: path) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
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
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(meal.eatenAt)))
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
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var previewImage: UIImage?
    @State private var savedPhotoPath: String?
    @State private var originalPhotoPath: String?
    @State private var suggestions: [MealImageClassifier.Suggestion] = []
    @State private var isClassifying: Bool = false
    @State private var showingCamera: Bool = false
    @State private var showingPhotoPicker: Bool = false
    @State private var nutritionEstimate: MealNutritionAnalyzer.Estimate?
    @State private var isAnalyzingNutrition: Bool = false
    @State private var nutritionError: String?
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
            _savedPhotoPath = State(initialValue: m.photoPath)
            _originalPhotoPath = State(initialValue: m.photoPath)
        } else {
            _mealType = State(initialValue: MealRecord.MealType.suggested())
            _eatenAt = State(initialValue: Date())
            _calories = State(initialValue: "")
            _protein = State(initialValue: "")
            _fat = State(initialValue: "")
            _carbs = State(initialValue: "")
            _notes = State(initialValue: "")
            _savedPhotoPath = State(initialValue: nil)
            _originalPhotoPath = State(initialValue: nil)
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
                Section("照片") {
                    if let img = previewImage {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
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
                            Label("从相册选择", systemImage: "photo.on.rectangle")
                        }
                    } label: {
                        Label(previewImage == nil && savedPhotoPath == nil ? "添加照片" : "更换照片", systemImage: "camera")
                    }
                    if previewImage != nil || savedPhotoPath != nil {
                        Button(role: .destructive) {
                            previewImage = nil
                            pickedPhoto = nil
                            suggestions = []
                            nutritionEstimate = nil
                            nutritionItems = []
                            nutritionError = nil
                            // If the user just imported a new photo this session (not the
                            // editing record's original), drop it from disk right away.
                            // The original photo (if any) is left alone — save() will GC it.
                            if let path = savedPhotoPath, path != originalPhotoPath {
                                MealPhotoStore.shared.removeIfManaged(path: path)
                            }
                            savedPhotoPath = nil
                        } label: {
                            Label("移除照片", systemImage: "trash")
                        }
                    }
                    if isClassifying {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("识别中…").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("本地识别（点击加入备注）")
                                .font(.caption).foregroundStyle(.secondary)
                            FlowLayout(spacing: 6) {
                                ForEach(suggestions, id: \.label) { s in
                                    Button {
                                        appendToNotes(s.label)
                                    } label: {
                                        Text(s.label + String(format: " %.0f%%", s.confidence * 100))
                                            .font(.footnote)
                                            .padding(.horizontal, 10).padding(.vertical, 5)
                                            .background(Color.accentColor.opacity(0.15))
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                if previewImage != nil {
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
            .onChange(of: pickedPhoto) { _, newItem in
                guard let newItem else { return }
                Task { await loadPicked(newItem) }
            }
            .photosPicker(
                isPresented: $showingPhotoPicker,
                selection: $pickedPhoto,
                matching: .images,
                photoLibrary: .shared()
            )
            .task {
                if previewImage == nil, let path = originalPhotoPath,
                   let img = MealPhotoStore.shared.loadImage(path: path) {
                    previewImage = img
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraPicker(
                    onImage: { img in
                        showingCamera = false
                        Task { await ingestCapturedImage(img) }
                    },
                    onCancel: { showingCamera = false }
                )
                .ignoresSafeArea()
            }
        }
    }

    private func loadPicked(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let img = UIImage(data: data) else { return }
        await ingestCapturedImage(img)
    }

    /// Shared post-capture pipeline used by both PhotosPicker and CameraPicker.
    /// Runs (a) on-device Vision classify (cheap, fast) and, if vision LLM is configured,
    /// (b) cloud nutrition estimate. Both kick off in parallel.
    private func ingestCapturedImage(_ img: UIImage) async {
        let saved = MealPhotoStore.shared.save(image: img)
        await MainActor.run {
            previewImage = img
            savedPhotoPath = saved
            isClassifying = true
            suggestions = []
            nutritionEstimate = nil
            nutritionItems = []
            nutritionError = nil
        }
        async let localTask: () = runLocalClassify(img)
        async let nutritionTask: () = runNutritionAnalysis(img)
        _ = await (localTask, nutritionTask)
    }

    private func runLocalClassify(_ img: UIImage) async {
        let s = await MealImageClassifier.classify(image: img)
        await MainActor.run {
            suggestions = s
            isClassifying = false
        }
    }

    private func runNutritionAnalysis(_ img: UIImage, userHint: String? = nil) async {
        guard LLMConfig.enabled, LLMConfig.isVisionConfigured else { return }
        await MainActor.run {
            isAnalyzingNutrition = true
            nutritionError = nil
        }
        do {
            let est = try await MealNutritionAnalyzer.analyze(image: img, userHint: userHint)
            await MainActor.run {
                nutritionEstimate = est
                nutritionItems = est.items.map(EditableNutritionItem.init(from:))
                isAnalyzingNutrition = false
                syncTotalsFromItems()
            }
        } catch {
            await MainActor.run {
                nutritionError = error.localizedDescription
                isAnalyzingNutrition = false
            }
            AppLogger.shared.error("Nutrition analysis failed: \(error.localizedDescription)")
        }
    }

    /// Build a "实际上是：米饭 100g、炒青菜 150g、…" hint from the current items and
    /// re-run the LLM. Items the user just added (empty name) are skipped from the
    /// hint but stay in the array, so they'll be replaced once the new estimate lands.
    private func reEstimateWithCorrection() async {
        guard let img = previewImage else { return }
        let parts: [String] = nutritionItems.compactMap { item in
            let n = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty else { return nil }
            let g = Int(item.grams.rounded())
            return g > 0 ? "\(n) \(g)g" : n
        }
        let hint = parts.joined(separator: "、")
        guard !hint.isEmpty else { return }
        await runNutritionAnalysis(img, userHint: hint)
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
                    Text("AI 估算营养中（首次约 3–8 秒）…")
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

                Button {
                    Task { await reEstimateWithCorrection() }
                } label: {
                    Label("按上方描述重新估算", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isAnalyzingNutrition || nutritionItems.allSatisfy { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

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

            if nutritionItems.isEmpty && !isAnalyzingNutrition && nutritionError == nil {
                if !LLMConfig.isVisionConfigured {
                    Text("未配置视觉模型。前往「设置 → AI 摘要」填入 Vision Model 字段（如 glm-4v-flash）即可自动估算。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("AI 估算营养")
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

    private func appendToNotes(_ label: String) {
        if notes.isEmpty {
            notes = label
        } else if !notes.contains(label) {
            notes += "、" + label
        }
    }

    private func save() async {
        let createdAt = editing?.createdAt ?? Int64(Date().timeIntervalSince1970)
        let record = MealRecord(
            id: editing?.id,
            mealType: mealType,
            eatenAt: Int64(eatenAt.timeIntervalSince1970),
            caloriesKcal: Double(calories),
            proteinG: Double(protein),
            fatG: Double(fat),
            carbsG: Double(carbs),
            photoPath: savedPhotoPath,
            notes: notes.isEmpty ? nil : notes,
            createdAt: createdAt
        )
        do {
            try await environment.database.asyncWrite { db in
                var r = record
                if r.id == nil {
                    try r.insert(db)
                } else {
                    try r.update(db)
                }
            }
            // Drop the previously-saved photo if the user swapped it for a new one
            // (or removed it) — but only after the DB write succeeds so we don't
            // strand a record pointing at a missing file on failure.
            if let old = originalPhotoPath, old != savedPhotoPath {
                MealPhotoStore.shared.removeIfManaged(path: old)
            }
        } catch {
            AppLogger.shared.error("Meal save failed: \(error.localizedDescription)")
        }
    }
}

/// Simple wrapping flow layout. Lays out children left-to-right; wraps when the next
/// child would overflow the proposed width. Used for the AI suggestion chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            maxX = max(maxX, x)
        }
        return CGSize(width: min(maxX, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x - bounds.minX + s.width > maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
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
