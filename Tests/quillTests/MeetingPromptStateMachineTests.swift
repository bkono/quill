import Foundation
import Testing
@testable import quill

@Suite
struct MeetingPromptStateMachineTests {
    private let epoch = Date(timeIntervalSince1970: 1_000)

    @Test
    func testStableCandidatePromptsOnceAfterConfirmationDelay() {
        let state = MeetingPromptStateMachine()
        let zoom = candidate(key: "zoom", delay: 3)

        #expect(state.evaluate(candidate: zoom, isRecording: false, now: at(0)) == .none)
        #expect(state.evaluate(candidate: zoom, isRecording: false, now: at(2.9)) == .none)

        guard case .show(let prompt) = state.evaluate(
            candidate: zoom,
            isRecording: false,
            now: at(3)
        ) else {
            Issue.record("expected a prompt after stable confirmation")
            return
        }

        #expect(prompt.candidate.key == "zoom")
        #expect(prompt.action == .startRecording)
        #expect(state.evaluate(candidate: zoom, isRecording: false, now: at(10)) == .none)
    }

    @Test
    func testInterruptedEvidenceRestartsConfirmationWindow() {
        let state = MeetingPromptStateMachine()
        let zoom = candidate(key: "zoom", delay: 3)

        #expect(state.evaluate(candidate: zoom, isRecording: false, now: at(0)) == .none)
        #expect(state.evaluate(candidate: nil, isRecording: false, now: at(2)) == .none)
        #expect(state.evaluate(candidate: zoom, isRecording: false, now: at(2.5)) == .none)
        #expect(state.evaluate(candidate: zoom, isRecording: false, now: at(5.4)) == .none)

        guard case .show = state.evaluate(
            candidate: zoom,
            isRecording: false,
            now: at(5.5)
        ) else {
            Issue.record("expected confirmation to restart when evidence returned")
            return
        }
    }

    @Test
    func testDismissalSuppressesSessionUntilEndGraceExpires() {
        let state = MeetingPromptStateMachine(endGracePeriod: 20)
        let zoom = candidate(key: "zoom", delay: 3)

        _ = state.evaluate(candidate: zoom, isRecording: false, now: at(0))
        guard case .show(let firstPrompt) = state.evaluate(
            candidate: zoom,
            isRecording: false,
            now: at(3)
        ) else {
            Issue.record("expected first prompt")
            return
        }

        #expect(state.dismiss(token: firstPrompt.token))
        #expect(state.evaluate(candidate: zoom, isRecording: false, now: at(8)) == .none)
        #expect(state.evaluate(candidate: nil, isRecording: false, now: at(27.9)) == .none)
        #expect(state.evaluate(candidate: nil, isRecording: false, now: at(28)) == .none)
        #expect(state.evaluate(candidate: zoom, isRecording: false, now: at(29)) == .none)

        guard case .show(let secondPrompt) = state.evaluate(
            candidate: zoom,
            isRecording: false,
            now: at(32)
        ) else {
            Issue.record("expected a new prompt for the next media session")
            return
        }

        #expect(secondPrompt.token != firstPrompt.token)
    }

    @Test
    func testManualRecordingStartHidesAndConsumesVisiblePrompt() {
        let state = MeetingPromptStateMachine()
        let zoom = candidate(key: "zoom", delay: 3)

        _ = state.evaluate(candidate: zoom, isRecording: false, now: at(0))
        guard case .show(let prompt) = state.evaluate(
            candidate: zoom,
            isRecording: false,
            now: at(3)
        ) else {
            Issue.record("expected prompt")
            return
        }

        #expect(state.evaluate(candidate: zoom, isRecording: true, now: at(4)) == .hide)
        #expect(!state.accept(token: prompt.token, action: .startRecording))
        #expect(state.evaluate(candidate: zoom, isRecording: false, now: at(5)) == .none)
    }

    @Test
    func testStaleActionsCannotAffectReplacementCandidate() {
        let state = MeetingPromptStateMachine()
        let zoom = candidate(key: "zoom", delay: 3)
        let teams = candidate(key: "teams", delay: 3)

        _ = state.evaluate(candidate: zoom, isRecording: false, now: at(0))
        guard case .show(let zoomPrompt) = state.evaluate(
            candidate: zoom,
            isRecording: false,
            now: at(3)
        ) else {
            Issue.record("expected Zoom prompt")
            return
        }

        #expect(state.evaluate(candidate: teams, isRecording: false, now: at(4)) == .hide)
        #expect(!state.accept(token: zoomPrompt.token, action: .startRecording))

        guard case .show(let teamsPrompt) = state.evaluate(
            candidate: teams,
            isRecording: false,
            now: at(7)
        ) else {
            Issue.record("expected Teams prompt")
            return
        }

        #expect(teamsPrompt.token != zoomPrompt.token)
        #expect(state.accept(token: teamsPrompt.token, action: .startRecording))
    }

    @Test
    func testRecordingShowsStopPromptOnlyAfterEndGrace() {
        let state = MeetingPromptStateMachine(endGracePeriod: 20)
        let zoom = candidate(key: "zoom", delay: 3)

        #expect(state.evaluate(candidate: zoom, isRecording: true, now: at(0)) == .none)
        #expect(state.evaluate(candidate: zoom, isRecording: true, now: at(5)) == .none)
        #expect(state.evaluate(candidate: nil, isRecording: true, now: at(24.9)) == .none)

        guard case .show(let prompt) = state.evaluate(
            candidate: nil,
            isRecording: true,
            now: at(25)
        ) else {
            Issue.record("expected a Stop prompt after the end grace period")
            return
        }

        #expect(prompt.action == .stopRecording)
        #expect(prompt.candidate.key == "zoom")
        #expect(state.evaluate(candidate: nil, isRecording: true, now: at(40)) == .none)
    }

    @Test
    func testEvidenceReturnCancelsStopAndInvalidatesItsToken() {
        let state = MeetingPromptStateMachine(endGracePeriod: 20)
        let zoom = candidate(key: "zoom", delay: 3)

        _ = state.evaluate(candidate: zoom, isRecording: true, now: at(0))
        guard case .show(let firstPrompt) = state.evaluate(
            candidate: nil,
            isRecording: true,
            now: at(20)
        ) else {
            Issue.record("expected first Stop prompt")
            return
        }

        #expect(state.evaluate(candidate: zoom, isRecording: true, now: at(21)) == .hide)
        #expect(!state.accept(token: firstPrompt.token, action: .stopRecording))
        #expect(state.evaluate(candidate: nil, isRecording: true, now: at(40.9)) == .none)

        guard case .show(let secondPrompt) = state.evaluate(
            candidate: nil,
            isRecording: true,
            now: at(41)
        ) else {
            Issue.record("expected a Stop prompt for the next absence episode")
            return
        }

        #expect(secondPrompt.token != firstPrompt.token)
    }

    @Test
    func testDismissedStopDoesNotRepeatWhileEvidenceRemainsMissing() {
        let state = MeetingPromptStateMachine(endGracePeriod: 20)
        let zoom = candidate(key: "zoom", delay: 3)

        _ = state.evaluate(candidate: zoom, isRecording: true, now: at(0))
        guard case .show(let prompt) = state.evaluate(
            candidate: nil,
            isRecording: true,
            now: at(20)
        ) else {
            Issue.record("expected Stop prompt")
            return
        }

        #expect(state.dismiss(token: prompt.token))
        #expect(state.evaluate(candidate: nil, isRecording: true, now: at(60)) == .none)
        #expect(!state.accept(token: prompt.token, action: .stopRecording))
    }

    @Test
    func testManualStopHidesAndInvalidatesVisibleStopPrompt() {
        let state = MeetingPromptStateMachine(endGracePeriod: 20)
        let zoom = candidate(key: "zoom", delay: 3)

        _ = state.evaluate(candidate: zoom, isRecording: true, now: at(0))
        guard case .show(let prompt) = state.evaluate(
            candidate: nil,
            isRecording: true,
            now: at(20)
        ) else {
            Issue.record("expected Stop prompt")
            return
        }

        #expect(state.evaluate(candidate: nil, isRecording: false, now: at(21)) == .hide)
        #expect(!state.accept(token: prompt.token, action: .stopRecording))
    }

    @Test
    func testStopPromptRejectsWrongAndRepeatedActions() {
        let state = MeetingPromptStateMachine(endGracePeriod: 20)
        let zoom = candidate(key: "zoom", delay: 3)

        _ = state.evaluate(candidate: zoom, isRecording: true, now: at(0))
        guard case .show(let prompt) = state.evaluate(
            candidate: nil,
            isRecording: true,
            now: at(20)
        ) else {
            Issue.record("expected Stop prompt")
            return
        }

        #expect(!state.accept(token: prompt.token, action: .startRecording))
        #expect(state.accept(token: prompt.token, action: .stopRecording))
        #expect(!state.accept(token: prompt.token, action: .stopRecording))
    }

    private func candidate(key: String, delay: TimeInterval) -> MeetingCandidate {
        MeetingCandidate(
            key: key,
            displayName: key.capitalized,
            sourceBundleID: "test.\(key)",
            sourcePID: 42,
            confirmationDelay: delay
        )
    }

    private func at(_ offset: TimeInterval) -> Date {
        epoch.addingTimeInterval(offset)
    }
}
