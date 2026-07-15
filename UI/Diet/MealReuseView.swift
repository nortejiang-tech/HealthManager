import SwiftUI

struct MealReuseView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var state: LoadState = .loading
    @State private var snapshots: [MealStore.Snapshot] = []
    @State private var selectedSnapshot: MealStore.Snapshot?
    @State private var selectedItemIds: Set<Int64> = []
    @State private var reusedCopyDraft: MealStore.CopyDraft?
    @State private var actionError: String?

    private enum LoadState: Equatable {
        case loading
        case ready
        case empty
        case failed(String)
    }

    var body: some View {
        if let copyDraft = reusedCopyDraft {
            MealEditView(copying: copyDraft)
        } else {
            NavigationStack {
                Group {
                    switch state {
                    case .loading:
                        ProgressView("加载历史餐次…")
                            .accessibilityIdentifier("meal-reuse-loading")
                    case .empty:
                        VStack(spacing: 8) {
                            Text("暂无可复用的历史餐次。")
                                .accessibilityIdentifier("meal-reuse-empty")
                            Button("刷新") {
                                Task {
                                    await loadRecentMeals()
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    case .failed(let message):
                        VStack(spacing: 8) {
                            Text("读取历史餐次失败：\(message)")
                                .multilineTextAlignment(.center)
                                .accessibilityIdentifier("meal-reuse-error")
                            Button("重试") {
                                Task {
                                    await loadRecentMeals()
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    case .ready:
                        if let selected = selectedSnapshot {
                            selectedMealView(selected)
                        } else {
                            snapshotList
                        }
                    }
                }
                .navigationTitle("复用餐次")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            dismiss()
                        }
                    }
                }
                .task {
                    await loadRecentMeals()
                }
            }
        }
    }

    @ViewBuilder
    private var snapshotList: some View {
        VStack(spacing: 0) {
            if let actionError {
                Text(actionError)
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }

            List {
                Section {
                    ForEach(snapshots, id: \.meal.id) { snapshot in
                        snapshotRow(snapshot)
                    }
                } header: {
                    Text("近期餐次")
                        .accessibilityIdentifier("meal-reuse-list")
                }
            }
        }
    }

    private func snapshotRow(_ snapshot: MealStore.Snapshot) -> some View {
        let mealId = snapshot.meal.id ?? -1
        let itemNames = snapshot.items.map(\.name)
        let trimmedNotes = snapshot.meal.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentSummary: String
        if !itemNames.isEmpty {
            contentSummary = itemNames.joined(separator: ", ")
        } else if let trimmedNotes, !trimmedNotes.isEmpty {
            contentSummary = trimmedNotes
        } else {
            contentSummary = "未记录饮食内容"
        }
        let nutritionSummary = [
            format(snapshot.meal.caloriesKcal, fallback: "—", suffix: "kcal"),
            format(snapshot.meal.proteinG, fallback: "—", suffix: "P"),
            format(snapshot.meal.fatG, fallback: "—", suffix: "F"),
            format(snapshot.meal.carbsG, fallback: "—", suffix: "C")
        ].joined(separator: " · ")

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.meal.mealType.label)
                        .font(.headline)
                        .accessibilityIdentifier("meal-reuse-row-\(mealId)")
                    Text(dateLabel(snapshot.meal.eatenAt))
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
                Spacer()
                Text(nutritionSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text(contentSummary)
                .font(.footnote)
                .lineLimit(2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("meal-reuse-content-\(mealId)")

            HStack {
                Button("复用整餐") {
                    Task {
                        await reuse(snapshot, with: .wholeMeal)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("meal-reuse-whole-\(mealId)")

                if !snapshot.items.isEmpty {
                    Button("选择菜品") {
                        selectedSnapshot = snapshot
                        selectedItemIds = []
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("meal-reuse-select-\(mealId)")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func selectedMealView(_ snapshot: MealStore.Snapshot) -> some View {
        let mealId = snapshot.meal.id ?? -1
        let childItems = snapshot.items

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("选择要复用的菜品")
                    .font(.headline)
                Spacer()
                Button("返回") {
                    selectedSnapshot = nil
                    selectedItemIds.removeAll()
                }
                .foregroundStyle(.tint)
            }

            Text("餐次：\(snapshot.meal.mealType.label) · \(dateLabel(snapshot.meal.eatenAt))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            List {
                ForEach(childItems, id: \.id) { item in
                    if let itemId = item.id {
                        let isSelected = selectedItemIds.contains(itemId)
                        Button {
                            toggleSelection(for: itemId)
                        } label: {
                            HStack {
                                Text(isSelected ? "✓" : "·")
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                Text(item.name)
                                Spacer()
                                if let grams = item.grams {
                                    Text(format(grams, fallback: "—"))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("meal-reuse-item-toggle-\(mealId)-\(itemId)")
                        .accessibilityLabel("选择\(item.name)")
                    } else {
                        HStack {
                            Text(item.name)
                            Spacer()
                            if let grams = item.grams {
                                Text(format(grams, fallback: "—"))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("meal-reuse-item-toggle-invalid")
                    }
                }
            }
            .listStyle(.plain)

            if let actionError {
                Text(actionError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button("确认复用选中菜品") {
                Task {
                    await reuse(snapshot, with: .itemIds(selectedItemIds))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedItemIds.isEmpty)
            .accessibilityIdentifier("meal-reuse-item-confirm")
            .padding(.horizontal)
        }
        .padding(.horizontal, 8)
    }

    private func toggleSelection(for itemId: Int64) {
        if selectedItemIds.contains(itemId) {
            selectedItemIds.remove(itemId)
        } else {
            selectedItemIds.insert(itemId)
        }
    }

    private func reuse(_ snapshot: MealStore.Snapshot, with selection: MealStore.CopySelection) async {
        actionError = nil
        do {
            let now = Date()
            let copyDraft = try environment.mealStore.makeCopyDraft(
                from: snapshot,
                selection: selection,
                targetMealType: MealRecord.MealType.suggested(for: now),
                eatenAt: Int64(now.timeIntervalSince1970)
            )
            reusedCopyDraft = copyDraft
        } catch {
            if let reuseError = error as? MealStore.ReuseError {
                switch reuseError {
                case .emptySelection:
                    actionError = "请至少选择一个菜品"
                case .missingItemIds(let ids):
                    actionError = "缺失分项：\(ids.map(String.init).joined(separator: ", "))"
                }
            } else {
                actionError = "复用失败：\(error.localizedDescription)"
            }
            AppLogger.shared.error("Reuse copy draft failed: \(error.localizedDescription)")
        }
    }

    private func loadRecentMeals() async {
        state = .loading
        actionError = nil
        selectedSnapshot = nil
        selectedItemIds.removeAll()
        do {
            let loaded = try await environment.mealStore.recentSnapshots(limit: 20, excludingMealId: nil)
            await MainActor.run {
                snapshots = loaded
                state = loaded.isEmpty ? .empty : .ready
            }
        } catch {
            if error is CancellationError {
                return
            }
            let message = error.localizedDescription
            AppLogger.shared.error("Load recent meals for reuse failed: \(message)")
            await MainActor.run {
                state = .failed(message)
            }
        }
    }

    private func dateLabel(_ epoch: Int64) -> String {
        AppDateFormats.shortDateTime.string(
            from: Date(timeIntervalSince1970: TimeInterval(epoch))
        )
    }

    private func format(_ value: Double?, fallback: String, suffix: String? = nil) -> String {
        guard let value else {
            return fallback
        }
        return format(value, fallback: fallback, suffix: suffix)
    }

    private func format(_ value: Double, fallback: String, suffix: String? = nil) -> String {
        guard value.isFinite else {
            return fallback
        }
        let text = value == value.rounded() ? String(format: "%.0f", value) : String(value)
        if let suffix {
            return "\(text)\(suffix)"
        }
        return text
    }
}

struct CommonGramSuggestionsRow: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Binding var item: MealItemDraft
    let index: Int

    @State private var suggestions: [MealStore.CommonGramSuggestion] = []

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            if !suggestions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.grams) { suggestion in
                        Button(suggestionLabel(suggestion)) {
                            item.gramsText = suggestionText(suggestion.grams)
                        }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("meal-item-common-grams-\(index)-\(suggestionText(suggestion.grams))")
                    }
                }
                .padding(.top, 2)
            }
        }
        .task(id: queryKey) {
            await refreshSuggestions()
        }
    }

    private var queryKey: String {
        "\(MealItemIdentity.canonicalName(item.name))|\(item.preparationState.rawValue)"
    }

    private func suggestionLabel(_ suggestion: MealStore.CommonGramSuggestion) -> String {
        "\(suggestionText(suggestion.grams))g"
    }

    private func suggestionText(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(value)
    }

    private var canLoadSuggestions: Bool {
        !MealItemIdentity.canonicalName(item.name).isEmpty
    }

    @MainActor
    private func refreshSuggestions() async {
        guard canLoadSuggestions else {
            suggestions = []
            return
        }

        suggestions = []
        do {
            try await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let source = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let fetched = try await environment.mealStore.commonGramSuggestions(
                forName: source,
                preparationState: item.preparationState,
                limit: 3
            )
            guard !Task.isCancelled else { return }
            suggestions = fetched
        } catch {
            guard !Task.isCancelled else { return }
            if error is CancellationError {
                return
            }
            suggestions = []
            AppLogger.shared.error("Load common gram suggestions failed: \(error.localizedDescription)")
        }
    }
}
