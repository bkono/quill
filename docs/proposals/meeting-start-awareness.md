# Proposal: Meeting Start Awareness

Status: implemented; direct provider validation in progress

Date: 2026-08-07

Updated: 2026-08-21

## 1. Normalized feature intent

Quill should notice when the user joins a call in a supported conferencing application and present a short-lived, actionable banner offering to start the existing two-track recording flow. If confirmed meeting evidence later remains absent while Quill is still recording, it should offer an equally explicit Stop action.

The detector must observe operating-system metadata only. It must not open the microphone, create a system-audio tap, inspect audio content, or start recording before the user explicitly accepts the prompt.

The target workflow is an ad-hoc Zoom meeting, Slack Huddle, or browser-hosted call that is easy to forget to record. Scheduled calendar reminders, exact browser-tab identification, automatic recording, and automatic stop are useful later extensions but are not required for the first useful version.

### Assumptions

- Quill continues to ship as one Swift executable launched directly or by its LaunchAgent.
- A generic “Call detected in Chrome” prompt is acceptable when Quill cannot identify the active tab without additional permissions.
- Manual menu-bar recording remains the authoritative fallback and must work when awareness fails or is disabled.
- Meeting awareness is enabled by default and may be disabled in config.

## 2. Problem and success criteria

Quill currently records reliably once the user chooses **Start recording**, but it has no signal that a meeting has begun. The failure mode is human: the user remembers the recorder after part or all of the meeting has passed.

V1 succeeds when:

- Zoom, Slack Huddle, and supported browser microphone activity produce one prompt after a short confirmation window.
- An idle-but-running Zoom, Slack, or browser process never produces a prompt.
- Pressing **Start Recording** invokes the existing `RecordingSession` path exactly once.
- Twenty seconds of missing meeting evidence while Quill is recording produces one **Stop Recording** prompt; it never stops automatically.
- Evidence returning or a manual stop closes and invalidates an outstanding Stop prompt.
- Dismissing or ignoring a prompt suppresses repeats until that continuous media session ends.
- Manual recording, transcription, and shutdown behavior remain intact.
- Detection itself produces no TCC prompt, recording indicator, or audio file.

V1 fails if it silently records, repeatedly prompts during one call, stops an active recording because of a stale action, or makes manual recording depend on the detector.

## 3. V1 scope, non-goals, and deferred scope

### In scope

- Enumerate Core Audio HAL process objects and read active input/output state, PID, and bundle ID.
- Correlate activity with a fixed set of conferencing applications and browser families.
- Require stable activity before prompting and a quiet grace period before considering the session ended.
- Present an in-process, non-activating AppKit panel with Start, Stop, and Dismiss actions.
- Add idempotent start-only and stop-only seams to `AppController`.
- Add a config switch, unit tests for deterministic policy, logging, and README documentation.

### Non-goals

- Audio sampling, voice activity detection, transcription, or content analysis before user consent.
- Zoom, Slack, or Google partner APIs and internal IPC.
- Calendar integration.
- Browser extensions or required Accessibility/Automation access.
- Exact Google Meet attribution when only browser process activity is available.
- Automatic start or automatic stop.
- Persistent recording overlays.

### Deferred

- Active-tab URL enrichment through Accessibility or Apple Events.
- Calendar context and meeting titles.
- Per-application enable/disable settings beyond the global switch.

## 4. Current repo context

Confirmed facts:

- `Run.runMain()` creates a long-lived `.accessory` `NSApplication` and an `AppController` before entering `app.run()` (`Sources/quill/Quill.swift`).
- `AppController` owns the only live `RecordingSession`, the menu-bar state, and recording start/stop transitions.
- `RecordingSession` already composes `SystemAudioRecorder` and `MicRecorder`; meeting awareness should call that boundary rather than either recorder directly.
- `notifyUser` shells out to `osascript display notification` and cannot route an action callback (`Sources/quill/Notify.swift`).
- Quill intentionally has no `.app` bundle. It embeds `Info.plist` in the executable and uses a LaunchAgent (`Package.swift`, `Sources/quill/Install.swift`).
- The prior persistent overlay was reverted in commit `60c1571`; a transient prompt must not resurrect always-on recording chrome.
- The package currently defines no test target.

The source of truth for whether Quill is recording remains `AppController.session`. Meeting awareness owns only observed external media activity and prompt suppression state.

### Existing research

- `docs/meeting-detection-research-1.md` records the selected Core Audio process-attribution approach.
- `docs/meeting-detection-research-2.md` contains an earlier window/process heuristic proposal. Its conclusion that window titles should be the primary signal is superseded by this proposal. Window or browser metadata remains optional enrichment only.

## 5. Repo-native adaptation map and mental model

| Source idea | Repo evidence | Quill adaptation | Rejected literal interpretation |
| --- | --- | --- | --- |
| Detect a call from mic ownership | Quill already links Core Audio for system capture | Read HAL process properties without creating a tap | Open the mic or analyze audio |
| Actionable desktop notification | Quill is a running accessory AppKit process | Transient non-activating `NSPanel` | Repackage as an app solely for `UNUserNotificationCenter` |
| Start or stop recording from a prompt | `AppController` owns `RecordingSession` | Add `startIfIdle(trigger:)` and `stopIfRecording(trigger:)` | Route through toggle and invert state from a stale action |
| Suppress notification spam | No existing meeting lifecycle state | Pure confirmation/session/suppression reducer | Arbitrary global cooldown disconnected from call end |

Mental model:

```text
Core Audio property changes / recovery sweep
    -> active process observations
    -> conferencing policy resolver
    -> continuous media-session state machine
    -> transient Start/Stop prompt
    -> idempotent AppController action
    -> existing RecordingSession
```

## 6. Existing behavior and patterns to extend

- AppKit state transitions remain main-actor isolated, matching `AppController` and `MenuBarController`.
- HAL access follows the property-address/getter conventions already used by `SystemAudioRecorder`.
- Detection errors are warnings written to stderr and degrade only awareness. They do not become Doctor hard failures.
- The existing passive `notifyUser` path remains available for recording/transcription failures and completion.
- Shutdown explicitly tears down every observer, timer, listener, prompt, and active recording.

## 7. Proposed v1 behavior

1. At daemon startup, Quill starts `MeetingAwarenessCoordinator` when awareness is enabled.
2. `CoreAudioProcessMonitor` listens for process-list and per-process input/output changes. A low-frequency recovery sweep repairs missed listeners after device/service churn.
3. The resolver normalizes helper bundle IDs to known parent applications and applies deterministic rules:
   - Zoom, Teams, and Webex: active input for at least three seconds.
   - Slack: active input and output for at least five seconds.
   - Chrome, Brave, Arc, Edge, and Safari: active input for at least three seconds; label as a browser call.
4. After confirmation, Quill shows one banner for the continuous session.
5. Start validates the prompt token and calls `AppController.startIfIdle(trigger: .meetingPrompt)`.
6. Dismiss and auto-dismiss suppress that media session until its evidence has been absent for twenty seconds.
7. Starting manually closes and suppresses any pending prompt. Stopping recording does not re-prompt while the same media session remains active.
8. While Quill is recording, twenty continuous seconds without meeting evidence produces one Stop prompt for that absence episode.
9. Evidence returning or recording stopping elsewhere closes the Stop prompt and rotates its token. Dismissal suppresses it until evidence returns; it never stops automatically.

Important edge cases:

- Chrome helper processes may own audio; normalize bundle-ID prefixes before applying policy.
- Input and output may be owned by different helpers; aggregate activity by normalized application.
- A stale, mismatched, or repeated Start/Stop action is a no-op when the prompt token is no longer current or recording state has already changed.
- Quill may launch during an active call; normal confirmation still yields one prompt.
- `coreaudiod` restart, sleep/wake, and listener loss are recovered by re-enumeration rather than failing the daemon.

## 8. Recommended implementation approach

### Observation

`CoreAudioProcessMonitor` reads:

- `kAudioHardwarePropertyProcessObjectList`
- `kAudioProcessPropertyPID`
- `kAudioProcessPropertyBundleID`
- `kAudioProcessPropertyIsRunningInput`
- `kAudioProcessPropertyIsRunningOutput`

It installs property listeners where available and compares sorted observations before notifying downstream consumers. A periodic sweep is recovery, not the semantic source of meeting state.

### Resolution

`MeetingCandidateResolver` is pure. It aggregates helper activity into one canonical application identity, applies the application policy, and returns at most one deterministic candidate.

### Lifecycle

`MeetingPromptStateMachine` owns confirmation, monotonically increasing prompt tokens, prompt disposition, dismissal/acceptance suppression, and end grace. It takes injected `Date` values so tests do not sleep. A token rotates when evidence returns after an end episode so delayed Stop clicks cannot affect a later episode.

Because HAL listeners are edge-triggered, the coordinator supplies a one-second lifecycle heartbeat. The heartbeat advances confirmation and end-grace deadlines; it does not poll for or redefine Core Audio evidence.

### Coordination and UI

`MeetingAwarenessCoordinator` connects the monitor, resolver, state machine, and `MeetingPromptController`. The coordinator never imports or calls recording internals; it emits explicit start-only and stop-only callbacks to `AppController`.

The prompt is a short-lived borderless `.nonactivatingPanel` with `.fullScreenAuxiliary` behavior. It must accept mouse clicks without activating Quill or stealing keyboard focus. The 460×136 banner uses an application-state accent, semantic symbol, readable hierarchy, 36-point actions, hover/pressed feedback, reduced-motion-aware entrance, and a twenty-second dwell.

### Alternatives rejected

- Window-title polling: permission-sensitive, app-version-sensitive, and weaker than actual audio-client state.
- Native notification actions: viable after adopting a normal app bundle, but unnecessary packaging expansion for this feature.
- Camera observation: corroborating signal only and public attribution is incomplete; private bridges are unacceptable as a core dependency.
- Virtual audio device: disproportionate complexity because Quill already captures system audio through public process taps.

## 9. Likely files/modules affected

| File/module | Expected change | Confidence |
| --- | --- | --- |
| `docs/proposals/meeting-start-awareness.md` | Durable decision and behavior lock | confirmed |
| `Sources/quill/MeetingAwareness/CoreAudioProcessMonitor.swift` | HAL observation and listeners | confirmed |
| `Sources/quill/MeetingAwareness/MeetingCandidateResolver.swift` | Pure application policy | confirmed |
| `Sources/quill/MeetingAwareness/MeetingPromptStateMachine.swift` | Pure lifecycle and suppression | confirmed |
| `Sources/quill/MeetingAwareness/MeetingAwarenessCoordinator.swift` | Orchestration boundary | confirmed |
| `Sources/quill/UI/MeetingPromptController.swift` | Transient actionable panel | confirmed |
| `Sources/quill/Quill.swift` | Lifecycle wiring and idempotent start/stop | confirmed |
| `Sources/quill/Config.swift` | Awareness enable switch | confirmed |
| `Package.swift` | Test target | confirmed |
| `Tests/quillTests/*` | Resolver and lifecycle regression tests | confirmed |
| `README.md` | Behavior/config/permission documentation | confirmed |

## 10. Data model, state, and persistence impact

No session schema or recording metadata changes are required.

Meeting observation, prompt token, and suppression state are process-local and ephemeral. Quill restart during a call may produce a new prompt after the confirmation delay; cross-restart suppression is intentionally deferred.

## 11. Config and UI surface changes

Optional config:

```json
{
  "meeting_awareness": {
    "enabled": true
  }
}
```

Missing config defaults to enabled. Invalid types fall back to the default using the existing config conventions.

The Start prompt presents:

- Title: `<Application> call detected`
- Body: `Record microphone and system audio as separate tracks.`
- Primary action: `Start Recording`
- Secondary action: `Not now` and dismiss button

The Stop prompt presents:

- Title: `<Application> call may have ended`
- Body: `Stop recording and begin transcription?`
- Primary action: `Stop Recording`
- Secondary action: `Not now` and dismiss button

Both automatically dismiss after twenty seconds without changing recording state.

## 12. Integration points and sequencing

1. Add the proposal and pure resolver/state-machine types.
2. Add the Core Audio monitor and recovery behavior.
3. Add the prompt controller and coordinator.
4. Add `AppController.startIfIdle(trigger:)`, `stopIfRecording(trigger:)`, coordinator lifecycle, and immediate recording-state notifications.
5. Add the config surface and README.
6. Add tests and perform manual provider validation.

## 13. Compatibility, migration, and rollout

- Existing config files remain valid.
- Existing recordings and transcripts are unchanged.
- Awareness may be disabled without affecting recording or transcription.
- Backout consists of disabling awareness or reverting the isolated coordinator wiring; no stored-data migration is involved.
- The LaunchAgent and single-binary install path remain unchanged.

## 14. Security, privacy, and trust boundaries

- Detection reads process metadata and Core Audio running-state properties only.
- No audio buffer exists until the user chooses Start.
- No new network request or third-party integration is introduced.
- Browser URLs, window titles, and calendar contents are not read in v1.
- The prompt is advisory and never constitutes recording consent on behalf of other participants; users remain responsible for applicable consent requirements.

## 15. Error handling and failure modes

- HAL property/listener failure: log a warning, keep recovery polling, preserve manual recording.
- Unknown/helper bundle: ignore unless it normalizes to a supported application.
- Prompt cannot obtain a screen: log and suppress the current media session rather than retrying continuously.
- Recording start fails: retain existing user notification and do not re-prompt the same media session.
- Stale or action-mismatched prompt callback: reject by prompt token and expected disposition.
- Shutdown: remove listeners/timers and close the prompt before stopping any live recording.

## 16. Testing strategy

Add a Swift test target and regression tests for:

- Resolver ignores process presence and output-only activity.
- Zoom/browser input becomes eligible; Slack input-only does not; Slack full duplex does.
- Helper processes aggregate under the canonical application.
- Confirmation delay prevents short spikes.
- A stable candidate prompts exactly once.
- Dismiss and auto-dismiss suppress until confirmed end.
- End followed by a new session prompts again.
- Manual recording hides/suppresses a pending prompt.
- Stale accept tokens are rejected.
- A candidate change hides the old prompt and confirms the new candidate independently.
- Missing evidence while recording produces one Stop prompt only after the full end grace.
- Evidence returning cancels the Stop prompt and invalidates its token.
- Stop dismissal does not repeat while evidence remains missing.
- Manual stop hides and invalidates an outstanding Stop prompt.
- Stop prompts reject Start actions and repeated Stop actions.

Manual acceptance must cover Zoom, Slack Huddle, and Chrome Meet across idle, prejoin, joined, muted, backgrounded, full-screen, end, Quill launch-mid-call, Dismiss, Start, manual start, and shutdown.

## 17. Risks and open questions

- Conferencing applications may keep audio streams warm before or after a call. The initial delays are evidence-based defaults but require field validation.
- Browser input is intentionally broader than Google Meet and may prompt for web dictation or voice chat. Exact URL enrichment is the likely follow-up if false positives are material.
- Multiple simultaneous call-capable applications are reduced to one deterministic candidate in v1.
- Runtime validation is required across AirPods, external interfaces, and aggregate devices even though attribution is process-based.
- Command Line Tools installations with mismatched SDK or Swift Testing runtime paths may require an explicit SDK/framework selection for local tests; the production target remains standard SwiftPM.

## 18. Handoff to implementation

The primary design decision is locked: Core Audio process activity is authoritative for v1. Review should focus on lifecycle correctness, listener cleanup, helper-process normalization, and preventing stale prompt actions from reaching the recording toggle.

Implementation must preserve the negative constraints below even if a provider proves difficult to detect.

## Decision ledger

### Decisions

- Per-process Core Audio input/output activity is the primary meeting signal because it observes actual media use without capturing content.
- Recording starts and stops only through explicit, idempotent `AppController` operations.
- A custom AppKit prompt preserves the single-binary distribution and avoids notification authorization/lifecycle expansion.
- End detection may offer a Stop action after a grace period; it never stops recording without an explicit click.

### Rejected / closed doors

- Window/process presence as the primary detector: too noisy and brittle.
- Audio capture or content analysis for detection: violates the consent boundary.
- Native actionable notifications in v1: implies unnecessary packaging and authorization work.
- Private camera identifiers or Control Center log parsing: unstable, undocumented dependencies.
- Browser extension, calendar integration, automatic start, and automatic stop: deferred; explicit user action remains invariant.

### Invariants

- At most one `RecordingSession` is live.
- Detection never opens an audio stream.
- One continuous external media session produces at most one Start prompt and one Stop prompt per confirmed absence episode.
- Manual recording and transcription do not depend on awareness.
- Detector failure degrades to manual behavior.

## Do Not

- Do not call the existing recording toggle from either prompt action.
- Do not reinterpret an open application as an active meeting.
- Do not reintroduce the reverted persistent overlay.
- Do not add required Accessibility, Automation, Calendar, or new capture permissions.
- Do not auto-stop a recording because a detector signal disappeared.

## Appendix A: Files inspected and evidence pointers

- `README.md`: product, single-binary distribution, recording and config behavior.
- `Package.swift`: executable-only package, embedded `Info.plist`, no test target.
- `Sources/quill/Quill.swift`: application and recording lifecycle ownership.
- `Sources/quill/UI/MenuBarController.swift`: existing persistent UI surface.
- `Sources/quill/Notify.swift`: passive, non-actionable notifications.
- `Sources/quill/RecordingSession.swift`: recording boundary and two-track ownership.
- `Sources/quill/Audio/SystemAudioRecorder.swift`: HAL conventions and process-tap lifecycle.
- `Sources/quill/Audio/MicRecorder.swift`: microphone capture and liveness fallback.
- `Sources/quill/Config.swift`: current JSON config conventions.
- `Sources/quill/Doctor.swift`: permission behavior and degraded-state expectations.
- `Sources/quill/Install.swift`: LaunchAgent and no-app-bundle decision.
- `docs/meeting-detection-research-1.md`: selected mechanism research.
- `docs/meeting-detection-research-2.md`: superseded window-primary alternative.
- macOS 15.4 Core Audio SDK headers: process-object and running-input/output properties.

## Appendix B: Likely implementation files

```text
Sources/quill/MeetingAwareness/CoreAudioProcessMonitor.swift
Sources/quill/MeetingAwareness/MeetingCandidateResolver.swift
Sources/quill/MeetingAwareness/MeetingPromptStateMachine.swift
Sources/quill/MeetingAwareness/MeetingAwarenessCoordinator.swift
Sources/quill/UI/MeetingPromptController.swift
Tests/quillTests/MeetingCandidateResolverTests.swift
Tests/quillTests/MeetingPromptStateMachineTests.swift
```
