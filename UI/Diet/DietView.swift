import SwiftUI
import PhotosUI
import GRDB

struct DietView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var meals: [MealRecord] = []
    @State private var showingAdd: Bool = false
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
                            MealRow(meal: meal)
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

    @State private var mealType: MealRecord.MealType = .breakfast
    @State private var eatenAt: Date = Date()
    @State private var calories: String = ""
    @State private var protein: String = ""
    @State private var fat: String = ""
    @State private var carbs: String = ""
    @State private var notes: String = ""
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var previewImage: UIImage?
    @State private var savedPhotoPath: String?

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
                    PhotosPicker(
                        selection: $pickedPhoto,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Label(previewImage == nil ? "添加照片" : "更换照片", systemImage: "camera")
                    }
                    if previewImage != nil {
                        Button(role: .destructive) {
                            previewImage = nil
                            pickedPhoto = nil
                            if let path = savedPhotoPath {
                                MealPhotoStore.shared.removeIfManaged(path: path)
                                savedPhotoPath = nil
                            }
                        } label: {
                            Label("移除照片", systemImage: "trash")
                        }
                    }
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
            .navigationTitle("添加餐次")
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
        }
    }

    private func loadPicked(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let img = UIImage(data: data) else { return }
        let saved = MealPhotoStore.shared.save(image: img)
        await MainActor.run {
            previewImage = img
            savedPhotoPath = saved
        }
    }

    private func save() async {
        let record = MealRecord(
            id: nil,
            mealType: mealType,
            eatenAt: Int64(eatenAt.timeIntervalSince1970),
            caloriesKcal: Double(calories),
            proteinG: Double(protein),
            fatG: Double(fat),
            carbsG: Double(carbs),
            photoPath: savedPhotoPath,
            notes: notes.isEmpty ? nil : notes,
            createdAt: Int64(Date().timeIntervalSince1970)
        )
        do {
            try await environment.database.asyncWrite { db in
                var r = record
                try r.insert(db)
            }
        } catch {
            AppLogger.shared.error("Meal save failed: \(error.localizedDescription)")
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
