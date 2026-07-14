import XCTest

@testable import HealthManager

final class MealItemEvidencePresentationTests: XCTestCase {
    func test_allProvenanceKindsMapToFixedSourceTitleAndSymbol() {
        let expectedTitleByKind: [MealItemRecord.ProvenanceKind: String] = [
            .manual: "手工录入",
            .aiEstimate: "AI 估算",
            .nutritionDatabase: "营养数据库",
            .nutritionLabel: "包装标签"
        ]

        let expectedSymbolByKind: [MealItemRecord.ProvenanceKind: String] = [
            .manual: "pencil",
            .aiEstimate: "sparkles",
            .nutritionDatabase: "book",
            .nutritionLabel: "tag"
        ]

        XCTAssertEqual(expectedTitleByKind.count, MealItemRecord.ProvenanceKind.allCases.count)
        XCTAssertEqual(expectedSymbolByKind.count, MealItemRecord.ProvenanceKind.allCases.count)

        for kind in MealItemRecord.ProvenanceKind.allCases {
            let presentation = MealItemEvidencePresentation(
                item: makeDraft(
                    provenanceKind: kind,
                    confidence: nil
                )
            )
            XCTAssertEqual(presentation.provenanceSourceTitle, expectedTitleByKind[kind])
            XCTAssertEqual(presentation.provenanceSymbolName, expectedSymbolByKind[kind])
        }
    }

    func test_confidenceMapForAllCasesAndNilFallback() {
        let expectedByConfidence: [MealItemRecord.Confidence: String] = [
            .low: "置信：低",
            .medium: "置信：中",
            .high: "置信：高"
        ]
        XCTAssertEqual(expectedByConfidence.count, MealItemRecord.Confidence.allCases.count)

        for (confidence, expected) in expectedByConfidence {
            let actual = MealItemEvidencePresentation(
                item: makeDraft(
                    provenanceKind: .aiEstimate,
                    confidence: confidence
                )
            )
            XCTAssertEqual(actual.compactConfidenceText, expected)
            XCTAssertEqual(actual.detailsConfidenceText, expected)
        }

        for kind in MealItemRecord.ProvenanceKind.allCases {
            let noConfidence = MealItemEvidencePresentation(
                item: makeDraft(
                    provenanceKind: kind,
                    confidence: nil
                )
            )
            if kind == .manual {
                XCTAssertNil(noConfidence.compactConfidenceText)
                XCTAssertEqual(noConfidence.detailsConfidenceText, "不适用（手工录入）")
            } else {
                XCTAssertEqual(noConfidence.compactConfidenceText, "置信未提供")
                XCTAssertEqual(noConfidence.detailsConfidenceText, "置信未提供")
            }
        }
    }

    func test_trimmedAndBlankReferenceAndVersionArePresentationOnly() {
        let draft = makeDraft(
            provenanceKind: .aiEstimate,
            confidence: .high,
            provenanceRef: "  model-x-v1  ",
            provenanceVersion: "   v2026.7   "
        )
        let presentation = MealItemEvidencePresentation(item: draft)

        XCTAssertEqual(presentation.referenceLineText, "引用：model-x-v1")
        XCTAssertEqual(presentation.versionLineText, "版本：v2026.7")
        XCTAssertEqual(draft.provenanceRef, "  model-x-v1  ")
        XCTAssertEqual(draft.provenanceVersion, "   v2026.7   ")

        let blankRefDraft = makeDraft(
            provenanceKind: .nutritionDatabase,
            confidence: .low,
            provenanceRef: "   ",
            provenanceVersion: "\n\t",
            name: "空白证据条目"
        )
        let blankPresentation = MealItemEvidencePresentation(item: blankRefDraft)
        XCTAssertNil(blankPresentation.referenceLineText)
        XCTAssertNil(blankPresentation.versionLineText)
        XCTAssertEqual(blankRefDraft.provenanceRef, "   ")
        XCTAssertEqual(blankRefDraft.provenanceVersion, "\n\t")
    }

    func test_manualWithStoredConfidenceDoesNotHideHistoricalFact() {
        let draft = makeDraft(
            provenanceKind: .manual,
            confidence: .high,
            isUserEdited: true,
            name: "手工条目"
        )
        let presentation = MealItemEvidencePresentation(item: draft)

        XCTAssertEqual(presentation.compactConfidenceText, "置信：高")
        XCTAssertEqual(presentation.compactRevisionText, "已人工修订")
        XCTAssertEqual(presentation.detailsConfidenceText, "置信：高")
        XCTAssertEqual(presentation.revisionLineText, "已人工修订")
        XCTAssertFalse(presentation.accessibilitySummaryText.contains("手工条目"))
        XCTAssertTrue(presentation.accessibilitySummaryText.contains("手工录入"))
    }

    func test_preparationStateMapsAllCasesAndCoverageCountsZeroAsKnownAndNilAsUnknown() {
        let expectedPreparationByState: [MealItemRecord.PreparationState: String] = [
            .unknown: "未标注",
            .raw: "生重",
            .cooked: "熟重"
        ]
        XCTAssertEqual(expectedPreparationByState.count, MealItemRecord.PreparationState.allCases.count)

        for (state, expected) in expectedPreparationByState {
            let draft = makeDraft(
                provenanceKind: .nutritionLabel,
                confidence: .low,
                preparationState: state
            )
            let presentation = MealItemEvidencePresentation(item: draft)
            XCTAssertEqual(presentation.preparationLineText, "备餐状态：\(expected)")
        }

        let partial = MealItemEvidencePresentation(
            item: makeDraft(
                provenanceKind: .nutritionLabel,
                confidence: .low,
                calories: 0,
                protein: nil,
                fat: 2,
                carbs: nil
            )
        )
        XCTAssertEqual(partial.coverageLineText, "营养字段：2/4 已记录")
        XCTAssertEqual(partial.unknownFieldsLineText, "未知：蛋白质、碳水")

        let allKnown = MealItemEvidencePresentation(
            item: makeDraft(
                provenanceKind: .nutritionLabel,
                confidence: .low,
                calories: 0,
                protein: 0,
                fat: 0,
                carbs: 0
            )
        )
        XCTAssertEqual(allKnown.coverageLineText, "营养字段：4/4 已记录")
        XCTAssertEqual(allKnown.unknownFieldsLineText, "未知：无")
    }

    func test_aiEvidenceKeepsReferenceVersionConfidenceRevisionPreparationAndCautionTogether() {
        let presentation = MealItemEvidencePresentation(
            item: makeDraft(
                provenanceKind: .aiEstimate,
                confidence: .high,
                provenanceRef: " model-health-v2 ",
                provenanceVersion: " 2026.07 ",
                isUserEdited: true,
                preparationState: .cooked,
                name: "AI 熟食"
            )
        )

        XCTAssertEqual(presentation.sourceLineText, "来源：AI 估算")
        XCTAssertEqual(presentation.referenceLineText, "引用：model-health-v2")
        XCTAssertEqual(presentation.versionLineText, "版本：2026.07")
        XCTAssertEqual(presentation.compactConfidenceText, "置信：高")
        XCTAssertEqual(presentation.detailsConfidenceText, "置信：高")
        XCTAssertEqual(presentation.compactRevisionText, "已人工修订")
        XCTAssertEqual(presentation.revisionLineText, "已人工修订")
        XCTAssertEqual(presentation.preparationLineText, "备餐状态：熟重")
        XCTAssertEqual(
            presentation.cautionLineText,
            "AI 结果是估算，置信度来自模型输出且未经过校准；保存前请核对菜名、份量和营养值。"
        )
    }

    func test_cautionTextIsExactAndContainsNoOverclaimTerms() {
        let expectedCautionByKind: [MealItemRecord.ProvenanceKind: String] = [
            .manual: "此条目由你手工录入；未附加独立数据来源。",
            .aiEstimate: "AI 结果是估算，置信度来自模型输出且未经过校准；保存前请核对菜名、份量和营养值。",
            .nutritionDatabase: "数据库来源名称或引用不等于该条目已经独立验证；请结合引用、版本和营养字段判断。",
            .nutritionLabel: "包装标签可能采用每份或每 100g 口径；当前未保存份量单位证据，不能视为已核对。"
        ]

        XCTAssertEqual(expectedCautionByKind.count, MealItemRecord.ProvenanceKind.allCases.count)

        for kind in MealItemRecord.ProvenanceKind.allCases {
            let presentation = MealItemEvidencePresentation(
                item: makeDraft(provenanceKind: kind)
            )
            XCTAssertEqual(presentation.cautionLineText, expectedCautionByKind[kind])
            XCTAssertFalse(presentation.cautionLineText.contains("临床级"))
            XCTAssertFalse(presentation.cautionLineText.contains("绝对准确"))
            XCTAssertFalse(presentation.cautionLineText.contains("准确率"))
            XCTAssertFalse(presentation.cautionLineText.contains("已验证"))
            XCTAssertFalse(presentation.cautionLineText.contains("%"))
        }
    }

    func test_revisedFactsFollowsCurrentBindingAndNoisyNameAndGramsChangesStaySticky() {
        let draftInput = makeDraft(
            provenanceKind: .aiEstimate,
            confidence: .medium,
            name: "初始条目",
            grams: 100
        )
        var draft = draftInput
        let initial = MealItemEvidencePresentation(item: draft)
        XCTAssertNil(initial.compactRevisionText)
        XCTAssertEqual(initial.revisionLineText, "未人工修订")

        draft.name = "更新条目"
        let afterRename = MealItemEvidencePresentation(item: draft)
        XCTAssertEqual(afterRename.compactRevisionText, "已人工修订")
        XCTAssertEqual(afterRename.revisionLineText, "已人工修订")
        XCTAssertTrue(draft.isUserEdited)
        draft.name = "重新命名回原"
        let afterRevert = MealItemEvidencePresentation(item: draft)
        XCTAssertEqual(afterRevert.revisionLineText, "已人工修订")

        draft.gramsText = "200"
        let afterGrams = MealItemEvidencePresentation(item: draft)
        XCTAssertEqual(afterGrams.revisionLineText, "已人工修订")
    }
}

private extension MealItemEvidencePresentationTests {
    func makeDraft(
        provenanceKind: MealItemRecord.ProvenanceKind,
        confidence: MealItemRecord.Confidence? = nil,
        provenanceRef: String? = nil,
        provenanceVersion: String? = nil,
        isUserEdited: Bool = false,
        preparationState: MealItemRecord.PreparationState = .unknown,
        name: String = "测试菜名",
        grams: Double? = nil,
        calories: Double? = nil,
        protein: Double? = nil,
        fat: Double? = nil,
        carbs: Double? = nil
    ) -> MealItemDraft {
        MealItemDraft(
            itemInput: MealStore.ItemInput(
                name: name,
                grams: grams,
                preparationState: preparationState,
                caloriesKcal: calories,
                proteinG: protein,
                fatG: fat,
                carbsG: carbs,
                provenanceKind: provenanceKind,
                provenanceRef: provenanceRef,
                provenanceVersion: provenanceVersion,
                confidence: confidence,
                isUserEdited: isUserEdited,
                createdAt: 1_000
            )
        )
    }
}
