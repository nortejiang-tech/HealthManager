import Foundation
import os.log

/// Lightweight, injectable startup phase recorder (C01 / S02).
///
/// Design constraints:
/// * The clock is injected so tests are deterministic; production defaults to
///   `ProcessInfo.processInfo.systemUptime`, which is monotonic across sleep and
///   therefore safe for elapsed-time accounting.
/// * Recording never reorders, delays, or gates the work it instruments. It only
///   appends an event and emits one structured log line.
/// * Log output is limited to session ID, milestone, sequence and elapsed
///   milliseconds. Database paths, health values and error bodies must never be
///   passed through this type.
@MainActor
final class StartupMetrics {
    /// Startup phase identifiers. Raw values are the stable log tokens.
    enum Milestone: String, Hashable {
        case environmentInitStarted = "environment_init_started"
        case databaseReady = "database_ready"
        case environmentReady = "environment_ready"
        case recoveryReady = "recovery_ready"
        case recoveryError = "recovery_error"
        case initialSnapshotRequested = "initial_snapshot_requested"
        case snapshotAvailable = "snapshot_available"
        case initialSnapshotError = "initial_snapshot_error"
    }

    /// One recorded phase transition.
    struct Event: Equatable {
        let sequence: Int
        let milestone: Milestone
        let elapsedMilliseconds: Int
    }

    let sessionID: UUID
    private(set) var events: [Event] = []

    private let monotonicNow: () -> TimeInterval
    private let startDate: TimeInterval
    private var recordedMilestones: Set<Milestone> = []
    private var initialSnapshotSettled: Bool = false
    private var nextSequence: Int = 1

    private let logger = Logger(subsystem: "com.norte.HealthManager", category: "startup")

    init(
        sessionID: UUID = UUID(),
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.sessionID = sessionID
        self.monotonicNow = monotonicNow
        self.startDate = monotonicNow()
    }

    /// Record `milestone` once for this session. Duplicate milestones are ignored,
    /// and the first of `snapshotAvailable` / `initialSnapshotError` wins so a
    /// failed initial read can never be reported as available.
    func record(_ milestone: Milestone) {
        guard !recordedMilestones.contains(milestone) else { return }

        switch milestone {
        case .snapshotAvailable, .initialSnapshotError:
            // First outcome on the initial snapshot wins; the other is dropped.
            if initialSnapshotSettled { return }
            initialSnapshotSettled = true
        case .environmentInitStarted, .databaseReady, .environmentReady,
             .recoveryReady, .recoveryError, .initialSnapshotRequested:
            break
        }

        recordedMilestones.insert(milestone)

        let elapsed = monotonicNow() - startDate
        // Negative clock drift is clamped to zero rather than logged as a
        // negative startup cost.
        let millis = elapsed <= 0 ? 0 : Int((elapsed * 1000).rounded())
        let sequence = nextSequence
        nextSequence += 1

        events.append(Event(sequence: sequence, milestone: milestone, elapsedMilliseconds: millis))
        let session = sessionID.uuidString
        let milestoneName = milestone.rawValue
        logger.info("startup session=\(session, privacy: .public) milestone=\(milestoneName, privacy: .public) sequence=\(sequence, privacy: .public) elapsedMs=\(millis, privacy: .public)")
    }
}
