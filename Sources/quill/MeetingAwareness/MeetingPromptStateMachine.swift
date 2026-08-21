import Foundation

struct MeetingPrompt: Equatable, Sendable {
    let sessionID: UInt64
    let candidate: MeetingCandidate
}

enum MeetingPromptDecision: Equatable, Sendable {
    case none
    case show(MeetingPrompt)
    case hide
}

/// Pure lifecycle policy for one continuous external media session. Callers
/// provide the clock so confirmation, end grace, and stale-action behavior can
/// be tested without timers or sleeps.
final class MeetingPromptStateMachine {
    private enum Disposition: Equatable {
        case pending
        case prompted
        case dismissed
        case accepted
    }

    private struct Session {
        let id: UInt64
        var candidate: MeetingCandidate
        var firstSeenAt: Date
        var lastSeenAt: Date
        var evidencePresent: Bool
        var disposition: Disposition
    }

    private let endGracePeriod: TimeInterval
    private var nextSessionID: UInt64 = 1
    private var session: Session?

    init(endGracePeriod: TimeInterval = 20) {
        self.endGracePeriod = endGracePeriod
    }

    func evaluate(
        candidate: MeetingCandidate?,
        isRecording: Bool,
        now: Date = Date()
    ) -> MeetingPromptDecision {
        guard let candidate else {
            return evaluateMissingCandidate(isRecording: isRecording, now: now)
        }

        if session?.candidate.key != candidate.key {
            let shouldHide = session?.disposition == .prompted
            session = makeSession(candidate: candidate, isRecording: isRecording, now: now)
            return shouldHide ? .hide : .none
        }

        guard var current = session else { return .none }
        current.candidate = candidate
        current.lastSeenAt = now

        // Confirmation requires continuous evidence. A transient disappearance
        // does not end the logical session until the grace period expires, but
        // it does restart the debounce window.
        if !current.evidencePresent, current.disposition == .pending {
            current.firstSeenAt = now
        }
        current.evidencePresent = true

        if isRecording {
            let shouldHide = current.disposition == .prompted
            current.disposition = .accepted
            session = current
            return shouldHide ? .hide : .none
        }

        guard current.disposition == .pending else {
            session = current
            return .none
        }

        guard now.timeIntervalSince(current.firstSeenAt) >= candidate.confirmationDelay else {
            session = current
            return .none
        }

        current.disposition = .prompted
        session = current
        return .show(MeetingPrompt(sessionID: current.id, candidate: candidate))
    }

    /// Suppress the current media session after either explicit or automatic
    /// dismissal. Returns false for stale prompt callbacks.
    @discardableResult
    func dismiss(sessionID: UInt64) -> Bool {
        guard var current = session,
              current.id == sessionID,
              current.disposition == .prompted else {
            return false
        }
        current.disposition = .dismissed
        session = current
        return true
    }

    /// Mark the prompt consumed before invoking recording startup. A failed
    /// recording start intentionally remains consumed to avoid retry storms.
    @discardableResult
    func accept(sessionID: UInt64) -> Bool {
        guard var current = session,
              current.id == sessionID,
              current.disposition == .prompted else {
            return false
        }
        current.disposition = .accepted
        session = current
        return true
    }

    private func makeSession(
        candidate: MeetingCandidate,
        isRecording: Bool,
        now: Date
    ) -> Session {
        defer { nextSessionID &+= 1 }
        return Session(
            id: nextSessionID,
            candidate: candidate,
            firstSeenAt: now,
            lastSeenAt: now,
            evidencePresent: true,
            disposition: isRecording ? .accepted : .pending
        )
    }

    private func evaluateMissingCandidate(
        isRecording: Bool,
        now: Date
    ) -> MeetingPromptDecision {
        guard var current = session else { return .none }
        current.evidencePresent = false

        if isRecording {
            let shouldHide = current.disposition == .prompted
            current.disposition = .accepted
            session = current
            return shouldHide ? .hide : .none
        }

        guard now.timeIntervalSince(current.lastSeenAt) >= endGracePeriod else {
            session = current
            return .none
        }

        let shouldHide = current.disposition == .prompted
        session = nil
        return shouldHide ? .hide : .none
    }
}
