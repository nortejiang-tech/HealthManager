import Foundation

/// PRD §5 state machine. Kept in a separate type so each phase has a single source of truth
/// and unit-testable transitions.
struct SyncStateMachine {

    enum Phase: Equatable {
        case idle
        case requestingAuth
        case backfilling
        case syncingIncremental
        case waitingExternalSync
        case syncingIncremental2
        case reconciling
        case completed
        case failed
    }

    enum Event {
        case startBackfill
        case startIncremental
        case startManual
        case authRequested
        case incrementalFinished
        case userPromptedForExternal
        case userResumedFromExternal
        case reconcileFinished
        case fail
        case reset
    }

    enum TransitionError: Error {
        case invalidTransition(from: Phase, event: Event)
    }

    private(set) var phase: Phase = .idle

    mutating func handle(_ event: Event) throws {
        switch (phase, event) {
        case (.idle, .startBackfill): phase = .backfilling
        case (.backfilling, .reconcileFinished): phase = .completed
        case (.backfilling, .fail): phase = .failed

        case (.idle, .startIncremental): phase = .syncingIncremental
        case (.syncingIncremental, .incrementalFinished): phase = .reconciling
        case (.reconciling, .reconcileFinished): phase = .completed
        case (.syncingIncremental, .fail), (.reconciling, .fail): phase = .failed

        case (.idle, .startManual): phase = .syncingIncremental
        case (.syncingIncremental, .userPromptedForExternal): phase = .waitingExternalSync
        case (.waitingExternalSync, .userResumedFromExternal): phase = .syncingIncremental2
        case (.syncingIncremental2, .incrementalFinished): phase = .reconciling

        case (.idle, .authRequested): phase = .requestingAuth
        case (.requestingAuth, .startBackfill): phase = .backfilling

        case (_, .reset): phase = .idle

        default:
            throw TransitionError.invalidTransition(from: phase, event: event)
        }
    }

    var isTerminal: Bool { phase == .completed || phase == .failed }
}
