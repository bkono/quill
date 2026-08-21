import Foundation

struct MeetingPrompt: Equatable, Sendable {
    let token: UInt64
    let candidate: MeetingCandidate
    let action: MeetingPromptAction
}

enum MeetingPromptAction: Equatable, Sendable {
    case startRecording
    case stopRecording
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
        case pendingStart
        case startPrompted
        case startDismissed
        case active
        case stopPrompted
        case stopDismissed
        case stopAccepted

        var isPrompted: Bool {
            self == .startPrompted || self == .stopPrompted
        }

        var belongsToStopCycle: Bool {
            self == .stopPrompted || self == .stopDismissed || self == .stopAccepted
        }
    }

    private struct Session {
        var promptToken: UInt64
        var candidate: MeetingCandidate
        var firstSeenAt: Date
        var lastSeenAt: Date
        var evidencePresent: Bool
        var disposition: Disposition
    }

    private let endGracePeriod: TimeInterval
    private var nextPromptToken: UInt64 = 1
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
            let shouldHide = session?.disposition.isPrompted ?? false
            session = makeSession(candidate: candidate, isRecording: isRecording, now: now)
            return shouldHide ? .hide : .none
        }

        guard var current = session else { return .none }
        current.candidate = candidate
        current.lastSeenAt = now

        // Confirmation requires continuous evidence. A transient disappearance
        // does not end the logical session until the grace period expires, but
        // it does restart the debounce window.
        let evidenceReturned = !current.evidencePresent
        let shouldHideStopPrompt = evidenceReturned && current.disposition == .stopPrompted
        if evidenceReturned {
            if current.disposition == .pendingStart {
                current.firstSeenAt = now
            } else if current.disposition.belongsToStopCycle {
                // A new absence episode must not accept a delayed action from
                // the previous Stop prompt.
                current.promptToken = takePromptToken()
                current.disposition = .active
            }
        }
        current.evidencePresent = true

        if isRecording {
            let shouldHide = shouldHideStopPrompt || current.disposition == .startPrompted
            current.disposition = .active
            session = current
            return shouldHide ? .hide : .none
        }

        if current.disposition == .stopPrompted {
            current.disposition = .active
            session = current
            return .hide
        }
        if current.disposition == .stopDismissed || current.disposition == .stopAccepted {
            current.disposition = .active
        }

        guard current.disposition == .pendingStart else {
            session = current
            return shouldHideStopPrompt ? .hide : .none
        }

        guard now.timeIntervalSince(current.firstSeenAt) >= candidate.confirmationDelay else {
            session = current
            return .none
        }

        current.disposition = .startPrompted
        session = current
        return .show(MeetingPrompt(
            token: current.promptToken,
            candidate: candidate,
            action: .startRecording
        ))
    }

    /// Suppress the current media session after either explicit or automatic
    /// dismissal. Returns false for stale prompt callbacks.
    @discardableResult
    func dismiss(token: UInt64) -> Bool {
        guard var current = session, current.promptToken == token else {
            return false
        }
        switch current.disposition {
        case .startPrompted:
            current.disposition = .startDismissed
        case .stopPrompted:
            current.disposition = .stopDismissed
        default:
            return false
        }
        session = current
        return true
    }

    /// Mark the matching prompt consumed before invoking the recording action.
    /// A failed action intentionally remains consumed to avoid retry storms.
    @discardableResult
    func accept(token: UInt64, action: MeetingPromptAction) -> Bool {
        guard var current = session,
              current.promptToken == token else {
            return false
        }
        switch (current.disposition, action) {
        case (.startPrompted, .startRecording):
            current.disposition = .active
        case (.stopPrompted, .stopRecording):
            current.disposition = .stopAccepted
        default:
            return false
        }
        session = current
        return true
    }

    private func makeSession(
        candidate: MeetingCandidate,
        isRecording: Bool,
        now: Date
    ) -> Session {
        return Session(
            promptToken: takePromptToken(),
            candidate: candidate,
            firstSeenAt: now,
            lastSeenAt: now,
            evidencePresent: true,
            disposition: isRecording ? .active : .pendingStart
        )
    }

    private func evaluateMissingCandidate(
        isRecording: Bool,
        now: Date
    ) -> MeetingPromptDecision {
        guard var current = session else { return .none }
        current.evidencePresent = false

        if isRecording {
            if current.disposition == .startPrompted {
                current.disposition = .active
                session = current
                return .hide
            }
            if current.disposition == .pendingStart || current.disposition == .startDismissed {
                current.disposition = .active
            }

            guard current.disposition == .active,
                  now.timeIntervalSince(current.lastSeenAt) >= endGracePeriod else {
                session = current
                return .none
            }

            current.disposition = .stopPrompted
            session = current
            return .show(MeetingPrompt(
                token: current.promptToken,
                candidate: current.candidate,
                action: .stopRecording
            ))
        }

        guard now.timeIntervalSince(current.lastSeenAt) >= endGracePeriod else {
            session = current
            return .none
        }

        let shouldHide = current.disposition.isPrompted
        session = nil
        return shouldHide ? .hide : .none
    }

    private func takePromptToken() -> UInt64 {
        defer { nextPromptToken &+= 1 }
        return nextPromptToken
    }
}
