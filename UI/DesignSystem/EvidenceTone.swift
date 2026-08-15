import SwiftUI

/// ADR-002 证据语义色角色的唯一决策点。
///
/// 所有「证据状态 → HMSemanticTone」的判断必须经过这里，视图不得自行 switch。
/// 历史教训：热量不完整曾被映射成估算色（应为缺失色）、用药动作曾绕过语义色
/// 直接使用系统红绿橙——决策散落必然漂移。
enum EvidenceTone {

    // MARK: - 饮食证据

    /// 当日热量证据三态 → 语义色。
    /// complete=已确认（青绿）；incomplete=缺失/未完成（珊瑚橙）；noMeals=无记录（中性）。
    static func forCalories(_ calories: DietCaloriesEvidence) -> HMSemanticTone {
        switch calories {
        case .complete:
            return .confirmed
        case .incomplete:
            return .actionRequired
        case .noMeals:
            return .neutral
        }
    }

    /// 饮食页加载状态 + 当日热量证据 → 语义色。
    static func forDietLoadState(
        _ loadState: DietLoadState,
        calories: DietCaloriesEvidence?
    ) -> HMSemanticTone {
        switch loadState {
        case .loading:
            return .neutral
        case .failed, .stale:
            return .actionRequired
        case .loaded:
            return forCalories(calories ?? .noMeals)
        }
    }

    // MARK: - 今日页

    static func forQualityStyle(_ style: TodayEvidencePresentation.QualityPillStyle) -> HMSemanticTone {
        switch style {
        case .unreconciled:
            return .neutral
        case .reconciledNoAlerts:
            return .confirmed
        case .hasAlerts:
            return .actionRequired
        }
    }

    /// 今日决策透镜：有告警 → 需要处理；无告警但有今日记录 → 已确认；否则中性。
    static func forLens(
        qualityStyle: TodayEvidencePresentation.QualityPillStyle,
        hasTimelineRows: Bool
    ) -> HMSemanticTone {
        if qualityStyle == .hasAlerts { return .actionRequired }
        if hasTimelineRows { return .confirmed }
        return .neutral
    }

    // MARK: - 用药

    /// 用药动作 → 语义色。taken=已确认；skipped/deferred=未按计划完成、需要处理。
    static func forMedicationAction(_ action: MedicationLog.Action) -> HMSemanticTone {
        switch action {
        case .taken:
            return .confirmed
        case .skipped, .deferred:
            return .actionRequired
        }
    }

    // MARK: - 餐食分项来源

    /// 分项来源 → 语义色。manual=中性；AI=估算；数据库/标签=可比较的参考。
    static func forProvenance(_ kind: MealItemRecord.ProvenanceKind) -> HMSemanticTone {
        switch kind {
        case .manual:
            return .neutral
        case .aiEstimate:
            return .estimate
        case .nutritionDatabase, .nutritionLabel:
            return .comparison
        }
    }
}
