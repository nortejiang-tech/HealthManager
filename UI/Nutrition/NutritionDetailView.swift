import SwiftUI

/// 食材详情：每 100 g 与「本次 X g」并排展示；来源、生熟、口径与缺失语义完整保留。
/// 「加入饮食」只生成编辑器草稿（A11），不直接写餐次。
struct NutritionDetailView: View {
    let entry: FoodCatalogEntry
    let catalog: FoodCatalog?
    /// 本次份量（g，或饮料 mL）；nil 表示未输入。
    @State private var servingText: String = ""

    let onAddToMeal: (MealItemDraft) -> Void
    /// 非 nil 时显示「从参考表移除」菜单（该条目在个人参考表中）。
    var onRemove: (() -> Void)?

    @State private var selectedPortion: FoodPortion?

    @Environment(\.dismiss) private var dismiss

    private var serving: Double? {
        let trimmed = servingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite, value > 0 else { return nil }
        return value
    }

    private var scaledNutrients: FoodCatalogEntry.Nutrients? {
        guard let serving else { return nil }
        return FoodServingCalculator.scaled(entry.nutrients, serving: serving)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    servingCard
                    nutrientsCard
                    sourceCard
                    addToMealButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(HMColors.background.ignoresSafeArea())
            .navigationTitle(entry.nameZh)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .accessibilityIdentifier("nutrition-detail-close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if onRemove != nil {
                        Menu {
                            Button("从参考表移除", role: .destructive) {
                                onRemove?()
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("nutrition-detail-more")
                    }
                }
            }
        }
    }

    /// 官方「每份」快捷选择：点选即把该份克重填入份量（每份总营养 = 每100g × 克重 ÷ 100）。
    @ViewBuilder
    private var portionChips: some View {
        if !entry.portions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("官方份定义")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(entry.portions, id: \.description) { portion in
                            Button {
                                selectedPortion = portion
                                servingText = Self.portionGramsText(portion)
                            } label: {
                                Text("\(portion.description) · \(Self.portionGramsText(portion))g")
                                    .font(.caption.weight(selectedPortion?.description == portion.description ? .semibold : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        selectedPortion?.description == portion.description
                                            ? HMColors.comparison.opacity(0.14) : Color.secondary.opacity(0.12),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(
                                        selectedPortion?.description == portion.description
                                            ? HMColors.comparison : Color.secondary
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("nutrition-portion-\(portion.description)")
                        }
                    }
                }
            }
        }
    }

    private static func portionGramsText(_ portion: FoodPortion) -> String {
        let w = portion.gramWeight
        return w == w.rounded() ? String(format: "%.0f", w) : String(w)
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.nameZh)
                    .font(.title2.weight(.bold))
                Text(entry.preparationState.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Text(entry.nameOriginal)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let refuse = entry.refusePercent, refuse > 0 {
                Label(
                    "官方废弃率 \(Int(refuse))%（蛋壳/壳皮/芯等），上方数值为可食部分，勿对已去废重量重复扣除。",
                    systemImage: "scalemass"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if !entry.portions.isEmpty {
                portionChips
            }
            if !entry.note.isEmpty {
                Text(entry.note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .hmSurface(cornerRadius: 18)
    }

    private var servingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本次份量")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                TextField("克", text: $servingText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("nutrition-serving-input")
                Text(unitLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if servingText.isEmpty {
                    Text("未输入")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if scaledNutrients == nil {
                    Text("克数需为正数")
                        .font(.footnote)
                        .foregroundStyle(HMColors.actionRequired)
                }
            }
            Text("参考值保持「\(entry.basis.displayUnit)」不变；下方「本次」只是按比例换算。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .hmSurface(cornerRadius: 18)
    }

    private var unitLabel: String {
        entry.basis == .per100mL ? "mL" : "g"
    }

    /// 「每 100」与「本次」两列并排，避免改重量后误以为参考值变了（§4.2）。
    private var nutrientsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("营养值")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if NutritionFormatting.isEstimated(entry.nutrients.kcal)
                    || NutritionFormatting.isEstimated(entry.nutrients.proteinG)
                    || NutritionFormatting.isEstimated(entry.nutrients.fatG)
                    || NutritionFormatting.isEstimated(entry.nutrients.carbsG) {
                    Text("含官方推定值")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            nutrientHeaderRow
            Divider().overlay(HMColors.separator)
            nutrientRow(
                label: "热量",
                unit: "kcal",
                per100: NutritionFormatting.kcal(entry.nutrients.kcal),
                scaled: scaledNutrients.map { NutritionFormatting.kcal($0.kcal) },
                estimated: NutritionFormatting.isEstimated(entry.nutrients.kcal)
            )
            nutrientRow(
                label: "蛋白质",
                unit: "g",
                per100: NutritionFormatting.macro(entry.nutrients.proteinG),
                scaled: scaledNutrients.map { NutritionFormatting.macro($0.proteinG) },
                estimated: NutritionFormatting.isEstimated(entry.nutrients.proteinG)
            )
            nutrientRow(
                label: "脂肪",
                unit: "g",
                per100: NutritionFormatting.macro(entry.nutrients.fatG),
                scaled: scaledNutrients.map { NutritionFormatting.macro($0.fatG) },
                estimated: NutritionFormatting.isEstimated(entry.nutrients.fatG)
            )
            nutrientRow(
                label: "碳水",
                unit: "g",
                per100: NutritionFormatting.macro(entry.nutrients.carbsG),
                scaled: scaledNutrients.map { NutritionFormatting.macro($0.carbsG) },
                estimated: NutritionFormatting.isEstimated(entry.nutrients.carbsG)
            )
            Divider().overlay(HMColors.separator)
            nutrientRow(
                label: "膳食纤维",
                unit: "g",
                per100: NutritionFormatting.macro(entry.nutrients.fiberG),
                scaled: scaledNutrients.map { NutritionFormatting.macro($0.fiberG) },
                estimated: NutritionFormatting.isEstimated(entry.nutrients.fiberG)
            )
            nutrientRow(
                label: "钠",
                unit: "mg",
                per100: NutritionFormatting.sodium(entry.nutrients.sodiumMg),
                scaled: scaledNutrients.map { NutritionFormatting.sodium($0.sodiumMg) },
                estimated: NutritionFormatting.isEstimated(entry.nutrients.sodiumMg)
            )
        }
        .padding(16)
        .hmSurface(cornerRadius: 18)
    }

    private var nutrientHeaderRow: some View {
        HStack {
            Text("项目")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(entry.basis.displayUnit)
                .font(.caption)
                .foregroundStyle(.secondary)
            if scaledNutrients != nil {
                Text("本次 \(servingText.trimmingCharacters(in: .whitespaces))\(unitLabel)")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
        }
    }

    private func nutrientRow(label: String, unit: String, per100: String, scaled: String?, estimated: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.callout)
                if estimated {
                    Text("推定")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(per100)
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 52, alignment: .trailing)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .leading)
            }
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(scaled ?? "—")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(scaled == nil ? Color.secondary : Color.primary)
                    .frame(minWidth: 52, alignment: .trailing)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .leading)
            }
            .frame(width: scaledNutrients != nil ? nil : 0, alignment: .trailing)
            .opacity(scaledNutrients != nil ? 1 : 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("出处")
                .font(.subheadline.weight(.semibold))
            if let catalog {
                Text(catalog.source.agency)
                Text(catalog.source.edition)
            }
            Text(entry.sourceCitation)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let sourceURL = URL(string: entry.sourceUrl) {
                Link(destination: sourceURL) {
                    Label("查看来源", systemImage: "safari")
                        .font(.subheadline.weight(.medium))
                }
                .accessibilityIdentifier("nutrition-source-link")
            } else {
                Text(entry.sourceUrl)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("翻译/中文名不是新数据源；数值以原始官方条目为准。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .hmSurface(cornerRadius: 18)
    }

    private var addToMealButton: some View {
        Button {
            let draft = MealItemDraft.fromCatalogEntry(
                entry,
                catalogVersion: catalog?.source.edition ?? entry.source,
                grams: selectedPortion?.gramWeight
            )
            onAddToMeal(draft)
        } label: {
            Text("加入饮食")
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(HMColors.primaryAction)
        .accessibilityIdentifier("nutrition-add-to-meal")
    }
}
