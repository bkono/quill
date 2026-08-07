They detect meeting activity by observing which process owns an active microphone stream—not by recording or analyzing audio.

This is explicitly documented by [Notion](https://www.notion.com/help/ai-meeting-notes), [Circleback](https://support.circleback.ai/en/articles/10460578-record-meetings-with-the-desktop-app), and [Dial8](https://dial8.ai/docs/desktop-app). Mem documents the behavior but not its implementation. Assuming `monologue.run`, its public materials describe dictation only, so that may be a different Monologue.

## The macOS mechanism

Core Audio exposes HAL process objects:

- [`kAudioHardwarePropertyProcessObjectList`](https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertyprocessobjectlist) enumerates every process connected to the audio system.
- Each object exposes PID, bundle ID, devices, and:
  - `kAudioProcessPropertyIsRunningInput`
  - `kAudioProcessPropertyIsRunningOutput`
- `kAudioDevicePropertyDeviceIsRunningSomewhere` provides an inexpensive event edge when microphone activity starts or stops.

The detector therefore does roughly this:

```text
microphone activity changed
        ↓
enumerate active Core Audio process objects
        ↓
PID + bundle ID + input/output state
        ↓
match Zoom / Slack / browser allowlist
        ↓
require stable evidence for 3–5 seconds
        ↓
show one actionable prompt for that continuous session
```

This does not open the microphone, create a process tap, or inspect audio. Detection itself requires no capture permission. Quill’s existing microphone and system-audio permissions are only needed after the user presses Start.

A current open-source implementation, [Muesli](https://github.com/Muesli-HQ/muesli/tree/v0.8.1), uses exactly this approach in its [Core Audio process collector](https://github.com/Muesli-HQ/muesli/blob/v0.8.1/native/MuesliNative/Sources/MuesliNativeApp/AudioProcessAttributionCollector.swift#L30-L55).

### Browser meetings

Core Audio can say “Chrome is using the microphone,” but not which tab.

There are two levels of support:

- Permission-free: prompt with “Call detected in Chrome.” This catches Google Meet and other browser calls.
- Exact classification: query the focused browser window’s `kAXDocumentAttribute`, use AppleScript/ScriptingBridge for the active-tab URL, or install a browser extension. This can verify `meet.google.com/xxx-yyyy-zzz`, but introduces Accessibility/Automation permission and background-tab ambiguity.

I recommend generic browser-call detection initially, with exact Meet URL attribution as optional enrichment.

## How I would add it to Quill

Add four isolated components:

```text
MeetingAwareness/
  CoreAudioProcessMonitor.swift
  MeetingCandidateResolver.swift
  MeetingPromptStateMachine.swift

UI/
  MeetingPromptController.swift
```

Suggested policy:

| Application            | Confirmation rule                                    |
| ---------------------- | ---------------------------------------------------- |
| Zoom                   | Input active for 3 seconds; input + output preferred |
| Slack                  | Input + output active for 5 seconds                  |
| Chrome/Arc/Safari/Edge | Input active; recognized meeting URL when available  |
| Meeting end            | Evidence absent for 20–30 seconds                    |

The monitor should also re-register listeners after default-device changes, sleep/wake, and `coreaudiod` restarts.

### Quill integration seam

`AppController` already owns recording lifecycle in [Quill.swift](/Users/bkonowitz/src/github.com/digimata/quill/Sources/quill/Quill.swift:77). The prompt action should call a new idempotent operation:

```swift
func startIfIdle(trigger: RecordingTrigger)
```

It must not call the current `toggle()`. A stale or double-clicked action arriving after recording starts would otherwise stop the session because `toggle()` switches based on `session == nil`.

Detection and recording remain separate states:

```text
detected → prompted → user accepts → startIfIdle → RecordingSession
```

Dismissal should suppress further prompts until that continuous audio session ends. Meeting-end detection should dismiss a pending prompt, but initially should not automatically stop an active recording—brief HAL/browser gaps must not truncate a meeting.

### Actionable banner

The existing [Notify.swift](/Users/bkonowitz/src/github.com/digimata/quill/Sources/quill/Notify.swift:3) uses `osascript display notification`, which cannot route an action callback.

Two options:

1. Recommended: a transient borderless, non-activating `NSPanel` with Start and Dismiss buttons, 15-second timeout, and `.fullScreenAuxiliary`. This preserves Quill’s single-binary architecture and avoids stealing keyboard focus. Muesli uses this exact shape in its [meeting prompt controller](https://github.com/Muesli-HQ/muesli/blob/v0.8.1/native/MuesliNative/Sources/MuesliNativeApp/MeetingNotificationController.swift#L119-L132).

2. Native Notification Center action: use `UNNotificationCategory` and `UNNotificationAction`. Apple supports action buttons and delegate callbacks, but this adds notification authorization and makes reliable app identity/action launch a packaging concern. Quill intentionally ships without an app bundle, so I would not take that dependency for this feature.

The current `notifyUser` remains appropriate for passive completion/failure notifications; it is only unsuitable for actionable prompts.

## Do Not

- Do not open or sample the microphone for detection.
- Do not treat process launch as meeting start; Zoom, Slack, and Chrome remain open.
- Do not route the prompt through `toggle()`.
- Do not make Accessibility or browser automation a hard startup dependency.
- Do not depend on private camera `_connectionID` KVC or parsing Control Center logs.
- Do not auto-stop recording in the first version.

## Decision ledger

**Decisions**

- Use per-process Core Audio input/output activity as the primary signal.
- Use browser URL, calendar, and camera only as optional enrichment.
- Preserve the single binary with a custom non-activating prompt.
- Require explicit user action before recording.

**Closed doors**

- No audio-content analysis, virtual audio device, provider SDK, or browser extension in v1.
- No process-launch-only or URL-only detection.
- No automatic stop until real-world signal-loss behavior is characterized.

**Invariants**

- Manual menu recording remains authoritative.
- At most one `RecordingSession` can exist.
- Stale prompt actions are no-ops.
- Detector failure cannot disable manual recording.

## Handoff

- **Summary:** Verified the platform mechanism, competitor pattern, and Quill integration seams.
- **Validation:** Confirmed the required HAL properties exist in the installed macOS 15.4 SDK. Worktree remains clean on `feat/meeting-start-awareness`.
- **Status:** Design ready; no files changed.
- **Next steps:** Implement the Core Audio collector and pure state-machine tests first, then add the `NSPanel` prompt and exercise Zoom, Slack Huddle, and Chrome Meet against a manual acceptance matrix.
