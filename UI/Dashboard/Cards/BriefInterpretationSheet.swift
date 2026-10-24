import SwiftUI

/// Read-only sheet presenting an AI narrative that was validated against a
/// local health brief snapshot. All displayed values come from the snapshot.
struct BriefInterpretationSheet: View {
    let snapshot: HealthBriefSnapshot
    let narrative: BriefNarrative
    let onRegenerate: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    summarySection
                    todaySection
                    evidenceSection
                    boundariesSection
                    regenerateButton
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("AI解读")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                    .accessibilityIdentifier("health-brief-sheet-close")
                }
            }
        }
        .accessibilityIdentifier("health-brief-sheet")
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: stateSymbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(stateTint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(narrative.headline)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if narrative.headline != narrative.state.title {
                        Text(narrative.state.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(stateTint)
                    }
                }
            }

            Label("数据日期 \(snapshot.day)", systemImage: "calendar")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("解读基于生成时的数据快照")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Summary

    private var summarySection: some View {
        card(title: "小结", systemImage: "text.alignleft", tint: stateTint) {
            Text(narrative.summary)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("health-brief-sheet-summary")
        }
    }

    // MARK: - Today

    private var todaySection: some View {
        card(title: "今日安排", systemImage: "calendar.day.timeline.left", tint: stateTint) {
            VStack(alignment: .leading, spacing: 10) {
                Text(focusGuidance)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var focusGuidance: String {
        switch narrative.focus {
        case "observe":
            return "继续观察"
        case "routine":
            return "按原计划安排"
        case "conserve":
            return "放轻安排"
        default:
            return "继续观察"
        }
    }

    // MARK: - Evidence

    private var evidenceSection: some View {
        card(title: "解读依据", systemImage: "chart.bar.doc.horizontal", tint: stateTint) {
            if displayedFactors.isEmpty {
                Text("本次解读未引用具体指标。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(displayedFactors.enumerated()), id: \.offset) { _, factor in
                        factorRow(factor)
                    }
                }
            }
        }
    }

    private var displayedFactors: [BriefFactor] {
        Array(narrative.factors.prefix(3))
    }

    private func factorRow(_ factor: BriefFactor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: directionSymbol(for: factor.direction))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(directionTint(for: factor.direction))
                    .accessibilityHidden(true)
                Text(factor.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(factorEvidenceRows(for: factor), id: \.id) { row in
                evidenceValueRow(row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func evidenceValueRow(_ fact: BriefFact) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(fact.title).font(.callout.weight(.medium))
                    Text(measureText(for: fact)).font(.callout.monospacedDigit())
                    Text(fact.date.isEmpty ? placeholder : fact.date).font(.footnote).foregroundStyle(.secondary)
                    Text(fact.source.isEmpty ? placeholder : fact.source).font(.footnote).foregroundStyle(.secondary)
                }.fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(fact.title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(measureText(for: fact)).font(.callout.monospacedDigit()).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(fact.date.isEmpty ? placeholder : fact.date)
                    Text(fact.source.isEmpty ? placeholder : fact.source)
                }.font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !fact.note.isEmpty {
                Text(fact.note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func factorEvidenceRows(for factor: BriefFactor) -> [BriefFact] {
        factor.fact_ids.compactMap { factID in
            snapshot.facts.first { $0.id == factID }
        }
    }

    private func measureText(for fact: BriefFact) -> String {
        guard let value = fact.value, value.isFinite else {
            return placeholder
        }
        let unit = fact.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        if unit.isEmpty {
            return value.formatted()
        }
        return "\(value.formatted()) \(unit)"
    }

    private var placeholder: String { "—" }

    // MARK: - Boundaries

    private var boundariesSection: some View {
        card(title: "参考边界", systemImage: "shield.lefthalf.filled", tint: stateTint) {
            VStack(alignment: .leading, spacing: 10) {
                if narrative.state == .baseline {
                    boundaryRow(
                        "个人基线仍在建立中，当前数值只用于说明记录范围，不代表恢复好坏。"
                    )
                }
                ForEach(Array(deduplicatedLimitations.enumerated()), id: \.offset) { _, limitation in
                    boundaryRow(limitation)
                }
                boundaryRow("生活参考，非医疗结论或佳明训练准备评分。")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func boundaryRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var deduplicatedLimitations: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for limitation in snapshot.limitations + narrative.limitations {
            let key = limitation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(limitation)
        }
        return result
    }

    // MARK: - Actions

    private var regenerateButton: some View {
        Button {
            onRegenerate()
            dismiss()
        } label: {
            Label("重新解读", systemImage: "arrow.clockwise")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(stateTint)
        .accessibilityIdentifier("health-brief-sheet-regenerate")
    }

    // MARK: - Shared card container

    private func card<Content: View>(
        title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    // MARK: - State styling

    private var stateSymbol: String {
        narrative.state.symbol
    }

    private var stateTint: Color {
        switch narrative.state {
        case .limited:
            return .secondary
        case .baseline:
            return .teal
        case .steady:
            return .green
        case .caution:
            return .orange
        case .mixed:
            return .purple
        }
    }

    private func directionSymbol(for direction: String) -> String {
        switch direction {
        case "positive":
            return "arrow.up.right.circle"
        case "negative":
            return "arrow.down.right.circle"
        default:
            return "equal.circle"
        }
    }

    private func directionTint(for direction: String) -> Color {
        switch direction {
        case "positive":
            return .green
        case "negative":
            return .orange
        default:
            return .secondary
        }
    }
}

#Preview {
    let fact = BriefFact(
        id: HealthBriefRules.sleepFactID,
        title: "睡眠时长",
        value: 432,
        unit: "分钟",
        date: "2026-10-24",
        source: "本地健康记录",
        note: ""
    )
    let snapshot = HealthBriefSnapshot(
        id: "snapshot-1",
        day: "2026-10-24",
        phase: "晨间",
        facts: [fact],
        training: [],
        allowedStates: [.steady, .mixed],
        defaultState: .steady,
        localSummary: "睡眠与夜间 HRV 与个人基线一致，恢复状态较稳。",
        limitations: ["训练记录尚不完整，仅作背景参考。"]
    )
    let narrative = BriefNarrative(
        snapshot_id: snapshot.id,
        state: .steady,
        headline: "恢复较稳",
        summary: "睡眠与夜间 HRV 与个人基线一致，恢复状态较稳。",
        factors: [
            BriefFactor(
                fact_ids: [HealthBriefRules.sleepFactID],
                direction: "positive",
                text: "睡眠时长与近期记录一致"
            ),
        ],
        focus: "routine",
        limitations: ["训练记录尚不完整，仅作背景参考。"]
    )
    return BriefInterpretationSheet(snapshot: snapshot, narrative: narrative) {}
}
