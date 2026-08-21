import Foundation

/// Owns meeting observation and prompt lifecycle, but never recording itself.
/// AppController remains the sole recording state owner.
@MainActor
final class MeetingAwarenessCoordinator {
    var isRecordingProvider: (@MainActor () -> Bool)?
    var onStartRecording: (@MainActor () -> Void)?
    var onStopRecording: (@MainActor () -> Void)?

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
                onAction: { [weak self] token, action in
                    self?.actionRequested(token: token, action: action)
                },
                onDismiss: { [weak self] token in
                    self?.dismissed(token: token)
                }
            )
            if didShow {
                log("\(prompt.action.logName) prompt shown for \(prompt.candidate.key) token=\(prompt.token)")
            } else {
                stateMachine.dismiss(token: prompt.token)
                warn("no screen available for meeting prompt")
            }
        }
    }

    private func actionRequested(token: UInt64, action: MeetingPromptAction) {
        guard stateMachine.accept(token: token, action: action) else {
            warn("ignored stale \(action.logName) action for token \(token)")
            return
        }
        log("\(action.logName) prompt accepted token=\(token)")
        switch action {
        case .startRecording:
            onStartRecording?()
        case .stopRecording:
            onStopRecording?()
        }
    }

    private func dismissed(token: UInt64) {
        guard stateMachine.dismiss(token: token) else { return }
        log("prompt dismissed token=\(token)")
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("meeting awareness: \(message)\n".utf8))
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("meeting awareness: warning: \(message)\n".utf8))
    }
}

private extension MeetingPromptAction {
    var logName: String {
        switch self {
        case .startRecording: "start"
        case .stopRecording: "stop"
        }
    }
}
