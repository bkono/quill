import Foundation

/// Owns meeting observation and prompt lifecycle, but never recording itself.
/// AppController remains the sole recording state owner.
@MainActor
final class MeetingAwarenessCoordinator {
    var isRecordingProvider: (@MainActor () -> Bool)?
    var onStartRecording: (@MainActor () -> Void)?

    private let monitor = CoreAudioProcessMonitor()
    private let stateMachine = MeetingPromptStateMachine()
    private let promptController = MeetingPromptController()
    private var lastCandidate: MeetingCandidate?
    private var evaluationTimer: Timer?
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.onActivitiesChanged = { [weak self] activities in
            self?.handleActivities(activities)
        }
        monitor.start()
        evaluationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateCurrentState() }
        }
        log("started")
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        monitor.onActivitiesChanged = nil
        monitor.stop()
        evaluationTimer?.invalidate()
        evaluationTimer = nil
        promptController.close()
        lastCandidate = nil
        log("stopped")
    }

    /// Called immediately when Quill's own recording state changes so a manual
    /// start suppresses an already-visible prompt without waiting for HAL IO.
    func recordingStateChanged() {
        guard isStarted else { return }
        evaluateCurrentState()
    }

    private func handleActivities(_ activities: [AudioProcessActivity]) {
        guard isStarted else { return }
        let candidate = MeetingCandidateResolver.resolve(activities)
        if candidate?.key != lastCandidate?.key {
            if let candidate {
                log("candidate \(candidate.key) pid=\(candidate.sourcePID)")
            } else if lastCandidate != nil {
                log("candidate evidence ended")
            }
        }
        lastCandidate = candidate
        evaluateCurrentState()
    }

    /// Core Audio listeners are edge-triggered. The heartbeat advances
    /// confirmation and end-grace deadlines when no additional edge arrives.
    private func evaluateCurrentState() {
        guard isStarted else { return }
        apply(
            stateMachine.evaluate(
                candidate: lastCandidate,
                isRecording: isRecordingProvider?() ?? false
            )
        )
    }

    private func apply(_ decision: MeetingPromptDecision) {
        switch decision {
        case .none:
            break
        case .hide:
            promptController.close()
        case .show(let prompt):
            let didShow = promptController.show(
                prompt: prompt,
                onStart: { [weak self] sessionID in
                    self?.startRequested(sessionID: sessionID)
                },
                onDismiss: { [weak self] sessionID in
                    self?.dismissed(sessionID: sessionID)
                }
            )
            if didShow {
                log("prompt shown for \(prompt.candidate.key) session=\(prompt.sessionID)")
            } else {
                stateMachine.dismiss(sessionID: prompt.sessionID)
                warn("no screen available for meeting prompt")
            }
        }
    }

    private func startRequested(sessionID: UInt64) {
        guard stateMachine.accept(sessionID: sessionID) else {
            warn("ignored stale Start action for session \(sessionID)")
            return
        }
        log("prompt accepted session=\(sessionID)")
        onStartRecording?()
    }

    private func dismissed(sessionID: UInt64) {
        guard stateMachine.dismiss(sessionID: sessionID) else { return }
        log("prompt dismissed session=\(sessionID)")
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("meeting awareness: \(message)\n".utf8))
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("meeting awareness: warning: \(message)\n".utf8))
    }
}
