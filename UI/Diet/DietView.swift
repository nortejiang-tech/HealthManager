import SwiftUI
import PhotosUI
import GRDB
import UIKit

/// 餐次行与编辑器（MealEditView.swift）共用的宏量数值格式：非整数固定一位小数。
func mealNutritionText(_ value: Double) -> String {
    // 直接 String(value) 会露出 "33.300000000000004" 式浮点尾数。
    value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
}

enum DietLoadState: Equatable {
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

    private static let pageSize = 50

    @State private var meals: [MealRecord] = []
    @State private var activeSheet: DietSheetKind?
    @State private var todayNutrition: MealNutritionEvidenceWindow?
    @State private var loadState: DietLoadState = .loading
    @State private var refreshGeneration: Int = 0
    @State private var deleteErrorMessage: String?

    // 历史查询（A14）：搜索、日期筛选与分页——超过 50 条的旧餐可直达。
    @State private var searchText: String = ""
    @State private var filterDay: Date?
    @State private var showingDayPicker: Bool = false
    @State private var totalCount: Int?
    @State private var hasMore: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var searchDebounce: Task<Void, Never>?

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
                searchText: $searchText,
                filterDay: filterDay,
                totalCount: totalCount,
                hasMore: hasMore,
                isLoadingMore: isLoadingMore,
                onSearchTextChanged: {
                    scheduleSearchReload()
                },
                onClearDayFilter: {
                    filterDay = nil
                    Task { await reloadFirstPage() }
                },
                onPickToday: {
                    filterDay = Date()
                    Task { await reloadFirstPage() }
                },
                onOpenDayPicker: {
                    showingDayPicker = true
                },
                onLoadMore: {
                    await loadMore()
                },
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
            .sheet(isPresented: $showingDayPicker) {
                DietDayPickerSheet(
                    onConfirm: { day in
                        filterDay = day
                        showingDayPicker = false
                        Task { await reloadFirstPage() }
                    },
                    onCancel: {
                        showingDayPicker = false
                    }
                )
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

    // MARK: - 数据加载

    /// 全量刷新：今日营养证据 + 历史第一页。
    private func refresh() async {
        let (hadUsableContent, generation) = await MainActor.run {
            refreshGeneration += 1
            return (loadState.hasUsableContent, refreshGeneration)
        }
        if !hadUsableContent {
            await MainActor.run { loadState = .loading }
        }
        do {
            let evidence: MealNutritionEvidenceWindow = try await environment.database.asyncRead { db in
                let calendar = Calendar.current
                let dayStart = calendar.startOfDay(for: Date())
                return try MealNutritionEvidenceQuery.load(
                    db: db,
                    fromLocalDay: dayStart,
                    throughLocalDay: dayStart,
                    calendar: calendar
                )
            }
            await MainActor.run {
                guard generation == refreshGeneration else { return }
                todayNutrition = evidence
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
        await reloadFirstPage(generation: generation)
    }

    /// 按当前搜索/筛选重查第一页与总数（不改今日营养证据状态）。
    private func reloadFirstPage(generation: Int? = nil) async {
        do {
            let rows = try await environment.mealStore.historyPage(
                limit: Self.pageSize,
                offset: 0,
                searchText: searchText,
                localDay: filterDay
            )
            let count = try await environment.mealStore.historyTotalCount(
                searchText: searchText,
                localDay: filterDay
            )
            await MainActor.run {
                if let generation, generation != refreshGeneration { return }
                meals = rows
                totalCount = count
                hasMore = rows.count >= Self.pageSize && count > rows.count
            }
        } catch {
            AppLogger.shared.error("Diet history reload failed: \(error.localizedDescription)")
        }
    }

    private func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        await MainActor.run { isLoadingMore = true }
        defer { Task { await MainActor.run { isLoadingMore = false } } }
        do {
            let existingIds = Set(await MainActor.run { meals.compactMap(\.id) })
            let rows = try await environment.mealStore.historyPage(
                limit: Self.pageSize,
                offset: await MainActor.run { meals.count },
                searchText: searchText,
                localDay: filterDay
            )
            await MainActor.run {
                // 分页不重：按 id 去重后追加。
                let appended = rows.filter { meal in
                    guard let id = meal.id else { return true }
                    return !existingIds.contains(id)
                }
                meals.append(contentsOf: appended)
                hasMore = rows.count >= Self.pageSize
            }
        } catch {
            AppLogger.shared.error("Diet load-more failed: \(error.localizedDescription)")
        }
    }

    /// 搜索输入防抖：停顿 350ms 后重查第一页。
    private func scheduleSearchReload() {
        searchDebounce?.cancel()
        searchDebounce = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await reloadFirstPage()
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

/// 日期筛选选择器：确认后按所选本地自然日过滤历史。
private struct DietDayPickerSheet: View {
    @State private var selected: Date = Date()
    let onConfirm: (Date) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            DatePicker(
                "选择日期",
                selection: $selected,
                displayedComponents: [.date]
            )
            .datePickerStyle(.graphical)
            .padding(20)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("按此日期筛选") { onConfirm(selected) }
                }
            }
            .navigationTitle("按日期查看")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

private struct DietScreenContent: View {
    let loadState: DietLoadState
    let meals: [MealRecord]
    let todayNutrition: MealNutritionEvidenceWindow?
    @Binding var searchText: String
    let filterDay: Date?
    let totalCount: Int?
    let hasMore: Bool
    let isLoadingMore: Bool
    let onSearchTextChanged: () -> Void
    let onClearDayFilter: () -> Void
    let onPickToday: () -> Void
    let onOpenDayPicker: () -> Void
    let onLoadMore: () async -> Void
    let onAdd: () -> Void
    let onReuse: () -> Void
    let onMealTap: (MealRecord) -> Void
    let onDeleteMeal: (MealRecord) async -> Void
    let onRetry: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                searchField
                dayFilterChips

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
                            ? "当前仍显示上一次成功读取的内容；重试只更新今日汇总与历史列表。"
                            : "重试范围仅限今日汇总与历史列表读取。",
                        actionTitle: "重试",
                        onAction: {
                            Task { await onRetry() }
                        },
                        actionAccessibilityIdentifier: "diet-retry"
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(HMColors.background.ignoresSafeArea())
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索菜名或备注", text: $searchText)
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("diet-search")
                .onChange(of: searchText) { _, _ in
                    onSearchTextChanged()
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    onSearchTextChanged()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(HMColors.surface, in: RoundedRectangle(cornerRadius: HMRadius.cell, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HMRadius.cell, style: .continuous)
                .stroke(HMColors.separator, lineWidth: 1)
        )
    }

    private var dayFilterChips: some View {
        HStack(spacing: 8) {
            chip(title: "全部日期", isSelected: filterDay == nil, action: onClearDayFilter)
            chip(title: "今天", isSelected: isTodayFilter, action: onPickToday)
            chip(title: filterDay == nil || isTodayFilter ? "选日期…" : selectedDayLabel, isSelected: !isTodayFilter && filterDay != nil, action: onOpenDayPicker)
            Spacer()
            if let totalCount {
                Text("共 \(totalCount) 条")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var isTodayFilter: Bool {
        guard let filterDay else { return false }
        return Calendar.current.isDateInToday(filterDay)
    }

    private var selectedDayLabel: String {
        guard let filterDay else { return "选日期…" }
        return AppDateFormats.monthDay.string(from: filterDay)
    }

    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    isSelected ? HMColors.comparison.opacity(0.14) : HMColors.surface,
                    in: Capsule()
                )
                .overlay(Capsule().stroke(isSelected ? HMColors.comparison : HMColors.separator, lineWidth: 1))
                .foregroundStyle(isSelected ? HMColors.comparison : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
            hasMore: hasMore,
            isLoadingMore: isLoadingMore,
            onLoadMore: {
                await onLoadMore()
            },
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
                            tone: EvidenceTone.forDietLoadState(loadState, calories: nutrition?.calories),
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

                    if let totals = nutrition?.totals,
                       [totals.caloriesKcal, totals.proteinG, totals.fatG, totals.carbsG]
                        .contains(where: { $0 == nil }) {
                        HMEvidenceTag(
                            tone: .actionRequired,
                            text: "部分营养字段缺失，未知值显示“—”。",
                            systemImage: "exclamationmark.triangle"
                        )
                    }
                }
            }
        }
        .padding(16)
        .hmSurface()
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
    let loadState: DietLoadState
    let meals: [MealRecord]
    let hasMore: Bool
    let isLoadingMore: Bool
    let onLoadMore: () async -> Void
    let onMealTap: (MealRecord) -> Void
    let onDeleteMeal: (MealRecord) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("历史餐次")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                if loadState.hasUsableContent, !meals.isEmpty {
                    Text("已显示 \(meals.count) 条")
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
                        title: "暂无匹配餐次",
                        message: "没有符合条件的已保存餐次。可以从上方记录一次，或调整搜索与日期筛选。",
                        icon: "fork.knife",
                        tone: .neutral,
                        primaryActionTitle: nil,
                        secondaryActionTitle: nil
                    )
                } else {
                    // LazyVStack 自适应行高（此前 scrollDisabled List + 手算 86/156pt 行高，
                    // 两行备注/大字体下会截断）；删除走 SwipeToRemoveRow，与营养表/用药同一实现。
                    LazyVStack(spacing: 0) {
                        ForEach(Array(meals.enumerated()), id: \.element.id) { index, meal in
                            SwipeToRemoveRow(removeAccessibilityLabel: "删除该餐次") {
                                Button {
                                    onMealTap(meal)
                                } label: {
                                    MealRow(meal: meal)
                                        .padding(.vertical, 2)
                                }
                                .buttonStyle(.plain)
                                .contentShape(Rectangle())
                                .accessibilityIdentifier("meal-row-\(meal.id ?? -1)")
                                // 长按兜底：左滑是手势型入口，长按菜单给 VoiceOver、
                                // 误触困难的用户和自动化一条稳定可达的删除路径。
                                .contextMenu {
                                    Button(role: .destructive) {
                                        Task { await onDeleteMeal(meal) }
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            } onRemove: {
                                Task { await onDeleteMeal(meal) }
                            }

                            if index < meals.count - 1 {
                                Divider().overlay(HMColors.separator)
                            }
                        }

                        if hasMore {
                            Button {
                                Task { await onLoadMore() }
                            } label: {
                                HStack(spacing: 8) {
                                    if isLoadingMore {
                                        ProgressView().controlSize(.small)
                                    }
                                    Text(isLoadingMore ? "加载中…" : "加载更早的餐次")
                                        .font(.footnote.weight(.medium))
                                }
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoadingMore)
                            .accessibilityIdentifier("diet-load-more")
                        }
                    }
                }
            }
        }
        .padding(14)
        .hmSurface(cornerRadius: HMRadius.card)
    }
}

private struct MealRow: View {
    let meal: MealRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let firstPath = meal.photoPaths.first {
                if let img = MealPhotoStore.shared.loadThumbnail(path: firstPath) {
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
                } else {
                    // 照片文件不存在（例如从备份恢复后照片未随包导出）→ 明确占位，不静默消失。
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .frame(width: 56, height: 56)
                        VStack(spacing: 2) {
                            Image(systemName: "photo.badge.exclamationmark")
                            Text("照片已丢失")
                                .font(.system(size: 8))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("照片已丢失")
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(meal.mealType.label).font(.body.bold())
                    Spacer()
                    Text(dateLabel).font(.footnote).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text(nutritionText(meal.caloriesKcal, prefix: "", suffix: " kcal"))
                    Text(nutritionText(meal.proteinG, prefix: "蛋白 ", suffix: "g"))
                    Text(nutritionText(meal.fatG, prefix: "脂肪 ", suffix: "g"))
                    Text(nutritionText(meal.carbsG, prefix: "碳水 ", suffix: "g"))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
        searchText: .constant(""),
        filterDay: nil,
        totalCount: 1,
        hasMore: false,
        isLoadingMore: false,
        onSearchTextChanged: {},
        onClearDayFilter: {},
        onPickToday: {},
        onOpenDayPicker: {},
        onLoadMore: {},
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
        searchText: .constant(""),
        filterDay: nil,
        totalCount: 1,
        hasMore: false,
        isLoadingMore: false,
        onSearchTextChanged: {},
        onClearDayFilter: {},
        onPickToday: {},
        onOpenDayPicker: {},
        onLoadMore: {},
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
        searchText: .constant(""),
        filterDay: nil,
        totalCount: 1,
        hasMore: false,
        isLoadingMore: false,
        onSearchTextChanged: {},
        onClearDayFilter: {},
        onPickToday: {},
        onOpenDayPicker: {},
        onLoadMore: {},
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
        searchText: .constant(""),
        filterDay: nil,
        totalCount: 0,
        hasMore: false,
        isLoadingMore: false,
        onSearchTextChanged: {},
        onClearDayFilter: {},
        onPickToday: {},
        onOpenDayPicker: {},
        onLoadMore: {},
        onAdd: {},
        onReuse: {},
        onMealTap: { _ in },
        onDeleteMeal: { _ in },
        onRetry: {}
    )
    .environment(\.locale, Locale(identifier: "zh_CN"))
}
