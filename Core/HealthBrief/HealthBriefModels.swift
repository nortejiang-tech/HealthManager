import Foundation

// MARK: - Domain models (Foundation only, deterministic, no IO)

public struct BriefFact: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var value: Double?
    public var unit: String
    public var date: String
    public var source: String
    public var note: String
    public var observedAt: Double?

    public init(
        id: String,
        title: String,
        value: Double?,
        unit: String,
        date: String,
        source: String,
        note: String,
        observedAt: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.value = value
        self.unit = unit
        self.date = date
        self.source = source
        self.note = note
        self.observedAt = observedAt
    }
}

public struct BriefTrainingDay: Codable, Equatable, Sendable {
    public var date: String
    public var load: Double?
    public var minutes: Double?
    public var incomplete: Bool

    public init(
        date: String,
        load: Double?,
        minutes: Double?,
        incomplete: Bool
    ) {
        self.date = date
        self.load = load
        self.minutes = minutes
        self.incomplete = incomplete
    }
}

public enum BriefState: String, Codable, Equatable, Sendable, CaseIterable {
    case limited
    case baseline
    case steady
    case caution
    case mixed

    public var title: String {
        switch self {
        case .limited: return "参考有限"
        case .baseline: return "基线建立中"
        case .steady: return "恢复较稳"
        case .caution: return "留意恢复"
        case .mixed: return "信号不一"
        }
    }

    public var symbol: String {
        switch self {
        case .limited: return "questionmark.circle"
        case .baseline: return "hourglass"
        case .steady: return "checkmark.seal"
        case .caution: return "exclamationmark.triangle"
        case .mixed: return "scalemass"
        }
    }
}

public struct HealthBriefSnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var day: String
    public var phase: String
    public var facts: [BriefFact]
    public var training: [BriefTrainingDay]
    public var allowedStates: [BriefState]
    public var defaultState: BriefState
    public var localSummary: String
    public var limitations: [String]

    public init(
        id: String,
        day: String,
        phase: String,
        facts: [BriefFact],
        training: [BriefTrainingDay],
        allowedStates: [BriefState],
        defaultState: BriefState,
        localSummary: String,
        limitations: [String]
    ) {
        self.id = id
        self.day = day
        self.phase = phase
        self.facts = facts
        self.training = training
        self.allowedStates = allowedStates
        self.defaultState = defaultState
        self.localSummary = localSummary
        self.limitations = limitations
    }
}

public struct BriefFactor: Codable, Equatable, Sendable {
    public var fact_ids: [String]
    public var direction: String
    public var text: String

    public init(fact_ids: [String], direction: String, text: String) {
        self.fact_ids = fact_ids
        self.direction = direction
        self.text = text
    }
}

public struct BriefNarrative: Codable, Equatable, Sendable {
    public var snapshot_id: String
    public var state: BriefState
    public var headline: String
    public var summary: String
    public var factors: [BriefFactor]
    public var focus: String
    public var limitations: [String]

    public init(
        snapshot_id: String,
        state: BriefState,
        headline: String,
        summary: String,
        factors: [BriefFactor],
        focus: String,
        limitations: [String]
    ) {
        self.snapshot_id = snapshot_id
        self.state = state
        self.headline = headline
        self.summary = summary
        self.factors = factors
        self.focus = focus
        self.limitations = limitations
    }
}

// MARK: - Deterministic rules

public enum HealthBriefRules {
    /// Fact identifiers understood by the rule engine.
    public static let sleepFactID = "sleep"
    public static let hrvFactID = "hrv"
    public static let batteryFactID = "battery"
    public static let hrvBaselineFactID = "hrvBaseline"

    /// Baseline notes that count as an established personal baseline.
    public static let validBaselineNotes: Set<String> = ["BALANCED", "LOW", "POOR", "UNBALANCED"]

    public static let limitedSummary = "提供现有记录，等待昨晚睡眠与夜间 HRV 完整同步。"
    public static let baselineSummary = "已有睡眠和夜间 HRV，个人基线仍在建立，暂不判断恢复好坏。"

    private static func fact(_ facts: [BriefFact], id: String) -> BriefFact? {
        facts.first { $0.id == id }
    }

    /// A usable fact must carry a numeric value; freshness/date correctness is
    /// the caller's responsibility and is not re-checked here.
    private static func usable(_ fact: BriefFact?) -> Bool {
        guard let fact, let value = fact.value else { return false }
        return value.isFinite
    }

    private static func usable(_ facts: [BriefFact], id: String) -> Bool {
        usable(fact(facts, id: id))
    }

    /// Baseline is considered valid only when the note explicitly states an
    /// established status and the weekly average is positive.
    private static func baselineStatus(in facts: [BriefFact]) -> String? {
        guard let baseline = fact(facts, id: hrvBaselineFactID) else { return nil }
        guard let average = baseline.value, average.isFinite, average > 0 else { return nil }
        // A positive weekly average alone is not enough: the note must state
        // an established status explicitly.
        let note = baseline.note.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard validBaselineNotes.contains(note) else { return nil }
        return note
    }

    public static func make(
        id: String,
        day: String,
        phase: String,
        facts: [BriefFact],
        training: [BriefTrainingDay]
    ) -> HealthBriefSnapshot {
        var limitations: [String] = []

        let hasSleep = usable(facts, id: sleepFactID)
        let hasHRV = usable(facts, id: hrvFactID)

        // Not enough of the two required signals: nothing to reason about.
        if !(hasSleep && hasHRV) {
            if training.contains(where: { $0.incomplete }) {
                limitations.append("训练记录尚不完整，仅作背景参考。")
            }
            return HealthBriefSnapshot(
                id: id,
                day: day,
                phase: phase,
                facts: facts,
                training: training,
                allowedStates: [.limited],
                defaultState: .limited,
                localSummary: limitedSummary,
                limitations: limitations
            )
        }

        // Both signals present but no trustworthy personal baseline yet.
        guard let status = baselineStatus(in: facts) else {
            if training.contains(where: { $0.incomplete }) {
                limitations.append("训练记录尚不完整，仅作背景参考。")
            }
            return HealthBriefSnapshot(
                id: id,
                day: day,
                phase: phase,
                facts: facts,
                training: training,
                allowedStates: [.baseline],
                defaultState: .baseline,
                localSummary: baselineSummary,
                limitations: limitations
            )
        }

        let sleepValue = fact(facts, id: sleepFactID)!.value!
        let isPoor = sleepValue < 60 || status == "LOW" || status == "POOR" || status == "UNBALANCED"
        var isReassuring = sleepValue >= 75 && status == "BALANCED"

        // Body Battery may only downgrade a reassuring reading, never escalate.
        if isReassuring, let battery = fact(facts, id: batteryFactID)?.value,
           battery.isFinite, battery < 20 {
            isReassuring = false
            limitations.append("体感电量偏低，恢复判断保留。")
        }

        let allowedStates: [BriefState]
        let defaultState: BriefState
        let localSummary: String

        if isPoor {
            allowedStates = [.caution, .mixed]
            defaultState = .caution
            localSummary = "现有信号提示恢复负担偏高，建议以轻量安排为主。"
        } else if isReassuring {
            allowedStates = [.steady, .mixed]
            defaultState = .steady
            localSummary = "睡眠与夜间 HRV 与个人基线一致，恢复状态较稳。"
        } else {
            allowedStates = [.mixed]
            defaultState = .mixed
            localSummary = "各项信号方向不完全一致，保持观察。"
        }

        if training.contains(where: { $0.incomplete }) {
            limitations.append("训练记录尚不完整，仅作背景参考。")
        }

        return HealthBriefSnapshot(
            id: id,
            day: day,
            phase: phase,
            facts: facts,
            training: training,
            allowedStates: allowedStates,
            defaultState: defaultState,
            localSummary: localSummary,
            limitations: limitations
        )
    }

    // MARK: Narrative validation

    public static let allowedDirections: Set<String> = ["positive", "negative", "neutral"]
    public static let allowedFocusValues: Set<String> = ["conserve", "routine", "observe"]

    static let forbiddenProsePhrases: [String] = [
        "诊断", "患有", "确诊", "服药", "停药", "治疗", "加药",
        "保证", "必然", "HRV评分", "训练准备分",
    ]

    static func proseIsClean(_ prose: String) -> Bool {
        // Numbers must be rendered from local facts, never embedded in prose.
        if prose.contains(where: { $0 >= "0" && $0 <= "9" }) { return false }
        for phrase in forbiddenProsePhrases where prose.contains(phrase) { return false }
        return true
    }

    private static func characterCount(_ text: String) -> Int {
        text.count
    }

    public static func validate(narrative: BriefNarrative, for snapshot: HealthBriefSnapshot) -> Bool {
        guard narrative.snapshot_id == snapshot.id else { return false }
        guard snapshot.allowedStates.contains(narrative.state) else { return false }

        guard characterCount(narrative.headline) >= 1,
              characterCount(narrative.headline) <= 16 else { return false }
        guard characterCount(narrative.summary) >= 1,
              characterCount(narrative.summary) <= 60 else { return false }
        guard proseIsClean(narrative.headline), proseIsClean(narrative.summary) else { return false }

        if snapshot.defaultState == .baseline || snapshot.defaultState == .limited {
            guard narrative.summary == snapshot.localSummary,
                  narrative.headline == snapshot.defaultState.title,
                  narrative.focus == "observe",
                  narrative.factors.allSatisfy({ $0.direction == "neutral" }) else { return false }
        }
        guard narrative.factors.count <= 3 else { return false }
        for factor in narrative.factors {
            guard allowedDirections.contains(factor.direction) else { return false }
            guard characterCount(factor.text) >= 1, characterCount(factor.text) <= 40 else { return false }
            guard proseIsClean(factor.text) else { return false }

            guard !factor.fact_ids.isEmpty, factor.fact_ids.count <= 3 else { return false }
            guard Set(factor.fact_ids).count == factor.fact_ids.count else { return false }
            for factID in factor.fact_ids {
                guard let fact = snapshot.facts.first(where: { $0.id == factID }) else { return false }
                guard let value = fact.value, value.isFinite else { return false }
            }
        }

        guard allowedFocusValues.contains(narrative.focus) else { return false }
        // A steady reading must not recommend conserving; caution must not
        // recommend a normal routine.
        if narrative.state == .steady && narrative.focus == "conserve" { return false }
        if narrative.state == .caution && narrative.focus == "routine" { return false }

        guard narrative.limitations.count <= 4 else { return false }
        for limitation in narrative.limitations {
            guard characterCount(limitation) >= 1, characterCount(limitation) <= 60 else { return false }
            guard proseIsClean(limitation) else { return false }
        }

        return true
    }
}
