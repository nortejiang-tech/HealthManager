import SwiftUI

struct MealItemEvidencePresentation: Equatable {
    let provenanceSourceTitle: String
    let provenanceSymbolName: String
    let compactConfidenceText: String?
    let compactRevisionText: String?
    let detailsConfidenceText: String
    let sourceLineText: String
    let referenceLineText: String?
    let versionLineText: String?
    let revisionLineText: String
    let preparationLineText: String
    let coverageLineText: String
    let unknownFieldsLineText: String
    let cautionLineText: String
    let accessibilitySummaryText: String

    init(item: MealItemDraft) {
        let sourceMetadata = Self.sourceMetadata(for: item.provenanceKind)
        provenanceSourceTitle = sourceMetadata.title
        provenanceSymbolName = sourceMetadata.symbolName
        sourceLineText = "来源：\(provenanceSourceTitle)"

        let trimmedRef = Self.trimmedOrNil(item.provenanceRef)
        let trimmedVersion = Self.trimmedOrNil(item.provenanceVersion)

        let confidenceText = Self.confidenceText(
            kind: item.provenanceKind,
            confidence: item.confidence
        )
        detailsConfidenceText = confidenceText

        if item.provenanceKind == .manual && item.confidence == nil {
            compactConfidenceText = nil
        } else {
            compactConfidenceText = confidenceText
        }

        if item.isUserEdited {
            compactRevisionText = "已人工修订"
            revisionLineText = "已人工修订"
        } else if item.provenanceKind == .manual {
            compactRevisionText = nil
            revisionLineText = "原始手工录入"
        } else {
            compactRevisionText = nil
            revisionLineText = "未人工修订"
        }

        preparationLineText = "备餐状态：\(Self.preparationTitle(for: item.preparationState))"

        let knownNutritionCount = Self.knownNutritionCount(for: item)
        coverageLineText = "营养字段：\(knownNutritionCount)/4 已记录"
        unknownFieldsLineText = Self.unknownFieldsLineText(for: item)

        if let trimmedRef {
            referenceLineText = "引用：\(trimmedRef)"
        } else {
            referenceLineText = nil
        }

        if let trimmedVersion {
            versionLineText = "版本：\(trimmedVersion)"
        } else {
            versionLineText = nil
        }

        cautionLineText = sourceMetadata.cautionText
        accessibilitySummaryText = "\(provenanceSourceTitle)，\(confidenceText)，\(revisionLineText)，\(preparationLineText)"
    }

    private struct SourceMetadata {
        let title: String
        let symbolName: String
        let cautionText: String
    }

    private static func sourceMetadata(for kind: MealItemRecord.ProvenanceKind) -> SourceMetadata {
        switch kind {
        case .manual:
            return SourceMetadata(
                title: "手工录入",
                symbolName: "pencil",
                cautionText: "此条目由你手工录入；未附加独立数据来源。"
            )
        case .aiEstimate:
            return SourceMetadata(
                title: "AI 估算",
                symbolName: "sparkles",
                cautionText: "AI 结果是估算，置信度来自模型输出且未经过校准；保存前请核对菜名、份量和营养值。"
            )
        case .nutritionDatabase:
            return SourceMetadata(
                title: "营养数据库",
                symbolName: "book",
                cautionText: "数据库来源名称或引用不等于该条目已经独立验证；请结合引用、版本和营养字段判断。"
            )
        case .nutritionLabel:
            return SourceMetadata(
                title: "包装标签",
                symbolName: "tag",
                cautionText: "包装标签可能采用每份或每 100g 口径；当前未保存份量单位证据，不能视为已核对。"
            )
        }
    }

    private static func preparationTitle(for state: MealItemRecord.PreparationState) -> String {
        switch state {
        case .unknown:
            return "未标注"
        case .raw:
            return "生重"
        case .cooked:
            return "熟重"
        }
    }

    private static func trimmedOrNil(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func confidenceText(
        kind: MealItemRecord.ProvenanceKind,
        confidence: MealItemRecord.Confidence?
    ) -> String {
        if kind == .manual && confidence == nil {
            return "不适用（手工录入）"
        }
        guard let confidence else {
            return "置信未提供"
        }
        switch confidence {
        case .low:
            return "置信：低"
        case .medium:
            return "置信：中"
        case .high:
            return "置信：高"
        }
    }

    private static func knownNutritionCount(for item: MealItemDraft) -> Int {
        [
            item.calories != nil,
            item.protein != nil,
            item.fat != nil,
            item.carbs != nil
        ].filter { $0 }.count
    }

    private static func unknownFieldsLineText(for item: MealItemDraft) -> String {
        let unknown = [
            item.calories == nil ? "热量" : nil,
            item.protein == nil ? "蛋白质" : nil,
            item.fat == nil ? "脂肪" : nil,
            item.carbs == nil ? "碳水" : nil
        ]
        .compactMap { $0 }

        if unknown.isEmpty {
            return "未知：无"
        }
        return "未知：" + unknown.joined(separator: "、")
    }
}

struct MealItemEvidenceView: View {
    let item: MealItemDraft
    let index: Int
    @State private var isExpanded: Bool = false

    var body: some View {
        let presentation = MealItemEvidencePresentation(item: item)
        let itemName = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let itemDisplayName = itemName.isEmpty ? "该条目" : itemName

        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Label(
                        presentation.provenanceSourceTitle,
                        systemImage: presentation.provenanceSymbolName
                    )
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .fontWeight(.medium)

                    if let compactConfidence = presentation.compactConfidenceText {
                        Text(compactConfidence)
                            .foregroundStyle(.secondary)
                    }

                    if let compactRevision = presentation.compactRevisionText {
                        Text(compactRevision)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }

                    Spacer()
                    Text(isExpanded ? "收起" : "详情")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                        .font(.caption2)
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("meal-item-evidence-toggle-\(index)")
            .accessibilityLabel("\(itemDisplayName)，\(presentation.accessibilitySummaryText)")
            .accessibilityValue(isExpanded ? "已展开" : "已收起")
            .accessibilityHint("轻点可展开或收起来源依据")
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.12))
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    detailLine(presentation.sourceLineText, id: "source")
                    if let reference = presentation.referenceLineText {
                        detailLine(reference, id: "reference", selectable: true)
                    }
                    if let version = presentation.versionLineText {
                        detailLine(version, id: "version", selectable: true)
                    }
                    detailLine(presentation.detailsConfidenceText, id: "confidence")
                    detailLine(presentation.revisionLineText, id: "revision")
                    detailLine(presentation.preparationLineText, id: "preparation")
                    detailLine(presentation.coverageLineText, id: "coverage")
                    detailLine(presentation.unknownFieldsLineText, id: "unknown")
                    detailLine(presentation.cautionLineText, id: "caution")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .accessibilityElement(children: .contain)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func detailLine(
        _ text: String,
        id: String,
        selectable: Bool = false
    ) -> some View {
        if selectable {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(nil)
                .textSelection(.enabled)
                .accessibilityIdentifier("meal-item-evidence-\(id)-\(index)")
        } else {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(nil)
                .accessibilityIdentifier("meal-item-evidence-\(id)-\(index)")
        }
    }
}
