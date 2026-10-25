import SwiftUI

/// A plain value describing one candidate workout record from some source.
internal struct WorkoutChoiceOption: Identifiable, Sendable {
    let id: String
    let sourceName: String
    let start: Date
    let minutes: Double
    let distanceKm: Double?
    let energyKcal: Double?
}

/// Sheet letting the user pick which record source wins for one workout.
///
/// Dismissal is owned by this sheet: saving only closes the sheet after
/// `onSave` returns without throwing.
struct WorkoutRecordChoiceSheet: View {
    let options: [WorkoutChoiceOption]
    let unavailableMessage: String?
    let onSave: @MainActor (String?) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var pickedID: String?
    @State private var saving: Bool = false
    @State private var error: String?

    init(
        options: [WorkoutChoiceOption],
        selectedID: String?,
        unavailableMessage: String? = nil,
        onSave: @escaping @MainActor (String?) async throws -> Void
    ) {
        self.options = options
        self.unavailableMessage = unavailableMessage
        self.onSave = onSave
        _pickedID = State(initialValue: options.contains { $0.id == selectedID } ? selectedID : nil)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HeaderNote()
                    if let unavailableMessage {
                        UnavailableNote(message: unavailableMessage)
                    }
                } header: {
                    Text("选择记录")
                }
                Section {
                    AutomaticChoiceRow(isSelected: pickedID == nil) {
                        pick(nil)
                    }
                    ForEach(options) { option in
                        OptionRow(option: option, isSelected: pickedID == option.id) {
                            pick(option.id)
                        }
                    }
                } header: {
                    Text("候选记录")
                }
                if let error {
                    Section {
                        ErrorRow(message: error)
                    } header: {
                        Text("无法保存")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDisabled(saving)
            .disabled(saving)
            .navigationTitle("计入记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .disabled(saving)
                    .accessibilityIdentifier("workout-choice-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    ToolbarSaveButton(saving: saving) {
                        await save()
                    }
                }
            }
            .accessibilityIdentifier("workout-choice-sheet")
            .interactiveDismissDisabled(saving)
        }
    }

    private func pick(_ id: String?) {
        guard !saving else { return }
        error = nil
        pickedID = id
    }

    @MainActor
    private func save() async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await onSave(pickedID)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct HeaderNote: View {
    var body: some View {
        Text("选定记录优先，其他来源只补全缺失项，同次运动只统计一次。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("workout-choice-header")
    }
}

private struct UnavailableNote: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("workout-choice-unavailable")
    }
}

private struct ErrorRow: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "xmark.octagon.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("workout-choice-error")
    }
}

private struct AutomaticChoiceRow: View {
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                Text("自动选择")
                    .font(.body)
                    .foregroundStyle(.primary)
                Text("默认佳明优先，缺失由其他来源补全")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, 48)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workout-choice-auto")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .overlay(alignment: .trailing) {
            RadioMark(isSelected: isSelected).allowsHitTesting(false)
        }
    }
}

private struct OptionRow: View {
    let option: WorkoutChoiceOption
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                Text(option.sourceName)
                    .font(.body)
                    .foregroundStyle(.primary)
                MetricLine(
                    label: "时间",
                    value: WorkoutChoiceFormatting.dateTime(option.start)
                )
                MetricLine(label: "时长", value: WorkoutChoiceFormatting.duration(option.minutes))
                MetricLine(label: "距离", value: WorkoutChoiceFormatting.distance(option.distanceKm))
                MetricLine(label: "能量", value: WorkoutChoiceFormatting.energy(option.energyKcal))
            }
            .padding(.trailing, 48)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workout-choice-\(option.id)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .overlay(alignment: .trailing) {
            RadioMark(isSelected: isSelected).allowsHitTesting(false)
        }
    }
}

private struct MetricLine: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let label: String
    let value: String

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).foregroundStyle(.secondary)
                    Text(value).foregroundStyle(.primary)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(label).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(value).foregroundStyle(.primary)
                }
            }
        }.font(.footnote).fixedSize(horizontal: false, vertical: true)
    }
}

private struct RadioMark: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
    }
}

private struct ToolbarSaveButton: View {
    let saving: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            if saving {
                ProgressView().accessibilityLabel("保存中")
            } else {
                Text("保存")
            }
        }
        .disabled(saving)
        .accessibilityIdentifier("workout-choice-save")
    }
}

private enum WorkoutChoiceFormatting {
    static let missing = "—"

    private static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func dateTime(_ date: Date) -> String {
        dateTime.string(from: date)
    }

    static func duration(_ minutes: Double) -> String {
        guard minutes.isFinite, minutes >= 0 else { return missing }
        return minutes.formatted(.number.precision(.fractionLength(0...1))) + " 分钟"
    }

    static func distance(_ km: Double?) -> String {
        guard let km, km.isFinite, km > 0 else {
            return km != nil && km == 0 ? "0.0 公里" : missing
        }
        return String(format: "%.2f 公里", km)
    }

    static func energy(_ kcal: Double?) -> String {
        guard let kcal, kcal.isFinite, kcal > 0 else {
            return kcal != nil && kcal == 0 ? "0 kcal" : missing
        }
        return String(format: "%.0f kcal", kcal)
    }
}
