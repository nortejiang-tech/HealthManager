import Foundation

/// Compile a model proposal into the locally enforced display contract.
/// Model wording cannot override baseline gates, facts or numeric values.
enum HealthBriefGrounding {
    struct Prepared {
        let narrative: BriefNarrative
        let repairs: [String]
    }
    static func prepare(_ proposal: BriefNarrative, for snapshot: HealthBriefSnapshot) -> Prepared? {
        guard proposal.snapshot_id == snapshot.id else { return nil }
        var result = proposal
        var repairs: [String] = []
        let locked = snapshot.defaultState == .baseline || snapshot.defaultState == .limited
        if !snapshot.allowedStates.contains(result.state) {
            result.state = snapshot.defaultState; result.summary = snapshot.localSummary
            repairs.append("state_outside_local_gate")
        }
        if locked {
            if result.headline != snapshot.defaultState.title { repairs.append("baseline_headline_wording") }
            if result.summary != snapshot.localSummary { repairs.append("baseline_summary_wording") }
            if result.focus != "observe" { repairs.append("baseline_focus") }
            result.headline = snapshot.defaultState.title
            result.summary = snapshot.localSummary
            result.focus = "observe"
        } else {
            if !clean(result.headline, limit: 16) { result.headline = result.state.title; repairs.append("headline_format") }
            if !clean(result.summary, limit: 60) { result.summary = snapshot.localSummary; repairs.append("summary_format") }
            if !HealthBriefRules.allowedFocusValues.contains(result.focus) || (result.state == .steady && result.focus == "conserve") || (result.state == .caution && result.focus == "routine") {
                result.focus = "observe"; repairs.append("focus_outside_local_gate")
            }
        }
        let facts = Dictionary(snapshot.facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        result.factors = proposal.factors.prefix(3).enumerated().compactMap { index, factor in
            guard (1...3).contains(factor.fact_ids.count), Set(factor.fact_ids).count == factor.fact_ids.count,
                  factor.fact_ids.allSatisfy({ facts[$0]?.value?.isFinite == true }) else {
                repairs.append("factor_\(index)_unavailable_evidence"); return nil
            }
            var factor = factor
            // With an unfinished personal baseline, use neutral fact templates for
            // selected evidence; do not reuse a model's unsupported recovery claim.
            if locked || !clean(factor.text, limit: 40) || !HealthBriefRules.allowedDirections.contains(factor.direction) {
                factor.direction = "neutral"
                guard let id = factor.fact_ids.first, let text = neutralText(id) else { return nil }
                factor.text = text; repairs.append("factor_\(index)_grounded_template")
            }
            return factor
        }
        result.limitations = proposal.limitations.prefix(4).filter { clean($0, limit: 60) }
        guard HealthBriefRules.validate(narrative: result, for: snapshot) else { return nil }
        return Prepared(narrative: result, repairs: repairs)
    }
    private static func clean(_ text: String, limit: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && text.count <= limit && HealthBriefRules.proseIsClean(text)
    }
    private static func neutralText(_ id: String) -> String? {
        switch id {
        case "sleep": return "睡眠记录已形成，结合后续几晚继续观察。"
        case "hrv": return "夜间数据已同步，个人基线仍需积累。"
        case "battery": return "电量为最近分段观测，结合更新时间参考。"
        case "hrv7", "hrv28": return "近期夜间记录仅作描述，不代替个人基线。"
        case "training72h", "training7d", "training28d": return "结合近期已记录训练，缺测不当作休息。"
        case "hrvBaseline", "hrvBaselineUpper": return "个人基线来自佳明已形成的记录。"
        default: return nil
        }
    }
}
