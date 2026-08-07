How they do it

Mem, Monologue, Granola-class apps do not get a “meeting started” event from Zoom/Slack/Google. They infer call state from local OS signals and then surface a prompt. The usual stack is layered:

┌─────────────────────┬───────────────────────────────────────────────┬───────────────────────────┬───────────────────────────────────────┐
│ Signal │ What it catches │ Reliability │ Cost │
├─────────────────────┼───────────────────────────────────────────────┼───────────────────────────┼───────────────────────────────────────┤
│ Window / process │ Zoom meeting window, Slack huddle chrome, │ Primary for start │ Cheap; needs window metadata access │
│ heuristics │ Meet tab title, Teams call UI │ detection │ │
├─────────────────────┼───────────────────────────────────────────────┼───────────────────────────┼───────────────────────────────────────┤
│ Mic / audio-client │ App actually holding the mic / in a call │ Confirms start; main │ Harder on macOS; Granola notes admin │
│ activity │ │ signal for end │ rights for auto-end │
├─────────────────────┼───────────────────────────────────────────────┼───────────────────────────┼───────────────────────────────────────┤
│ Calendar (EventKit) │ Scheduled meetings before join │ Great for “starts in 2 │ Misses ad-hoc; needs calendar │
│ │ │ min” │ permission │
├─────────────────────┼───────────────────────────────────────────────┼───────────────────────────┼───────────────────────────────────────┤
│ Browser extension │ Meet/Teams-in-browser call state, speaker │ Best for pure browser │ Extra install surface │
│ │ names │ calls │ │
└─────────────────────┴───────────────────────────────────────────────┴───────────────────────────┴───────────────────────────────────────┘

Mem’s own product copy is explicit: calendar for scheduled, runtime detection for ad-hoc Zoom / Meet / Teams / Slack.

1. Window + process watching (the main trick)

A background agent polls (or listens for) system window metadata, typically:

• CGWindowListCopyWindowInfo → kCGWindowOwnerName / PID / kCGWindowName
• Optionally Accessibility (AXUIElement) for deeper UI (huddle panels, Meet “Leave call”)
• Bundle IDs via NSRunningApplication / NSWorkspace

Then match against known “in a call” fingerprints:

┌─────────────┬───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ App │ Typical signals │
├─────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Zoom │ Process us.zoom.xos (and often helper processes); window title patterns like meeting/webinar UI — not just “Zoom” open on │
│ │ the home screen │
├─────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Slack │ com.tinyspeck.slackmacgap + huddle-specific window/title/AX nodes (not every Slack window) │
│ huddle │ │
├─────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Google Meet │ Chrome/Arc/Safari window or tab title containing Meet patterns (Meet - …, meet.google.com) │
├─────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Teams │ Teams process + call/meeting window titles │
└─────────────┴───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

This is the same class of technique time-trackers (Timing) and meeting detectors document: read window titles / app identity, no call content. False positives are managed by title patterns and state machines, not “Zoom is running.” Meeting Mind’s changelog is a good tell: they constantly harden against Zoom hiding windows, ringtone/chat chimes, and title stripping on Sequoia/Tahoe.

Permission note (macOS): reading other apps’ window titles effectively requires Screen Recording (under Sequoia that’s the same “Screen & System Audio Recording” bucket). Quill already needs that TCC grant for Core Audio process taps, so detection does not introduce a new privacy category — it reuses an existing one.

2. Mic / Core Audio as confirmation + end detection

Apps cross-check that a conferencing process is an active audio client (mic open / purple-dot class signal). Granola is unusually candid here: for ad-hoc meetings, auto-stop is “call app stopped using the microphone,” and on macOS that path needs admin rights; without it, users stop manually.

That matches what you’d expect: start detection is mostly UI presence; end detection is UI gone + mic released, with timeouts for silence.

3. Calendar (optional second path)

EventKit + conference URLs (zoom.us/j/…, meet.google.com/…, Teams links) drive pre-meeting banners. That is complementary, not a substitute for “I just jumped into a huddle.”

4. The notification UX

The “banner with Start recording” is either:

1. UNUserNotificationCenter with a UNNotificationCategory + action (Start), or
2. A custom floating NSPanel banner (more control; no dependency on Notification Center action quirks).

Important for Quill: today’s Notify.swift is osascript display notification — title + body only, no action button. Actionable prompts need either UserNotifications (proper bundle / identity) or a custom panel.

───

What Quill has today

• Menu-bar daemon (.accessory), manual Start recording
• Two-track capture: mic + system audio process tap
• notifyUser via osascript (non-actionable)
• Branch name feat/meeting-start-awareness — feature intent is already scoped; implementation is not

So the gap is: observer → state machine → actionable prompt → existing RecordingSession.

───

How to recreate it in Quill

Recommended shape (fits quill’s minimalism)

MeetingWatcher (poll 1–2s)
→ signatures for Zoom / Slack / Meet / Teams
→ state machine: idle → candidate → offered → dismissed | recording
→ Prompt surface (panel or UN notification)
→ AppController.startSession() / stopSession() (already exists)

Do not auto-start recording without a click. Mem/Monologue style is prompt, not silent capture. That matches local-first ethics and avoids surprise purple-dot / legal issues.

Concrete detection design

A. Window poller (ship this first)

// Pseudo-structure — not drop-in
struct MeetingSignal: Equatable {
enum Platform { case zoom, slack, meet, teams }
let platform: Platform
let title: String?
let pid: pid_t
}

func scan() -> MeetingSignal? {
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
// match owner name / bundle + title regexes
// require "in-call" titles, not mere app presence
}

Heuristics to bake in early (or you’ll ship false positives day one):

• Debounce 2–5s of continuous match before offering
• Dwell: don’t re-prompt the same meeting for N minutes after Dismiss / after Stop
• Zoom: distinguish home/settings vs meeting window; ignore ring/chat-only flashes
• Meet: browser titles are flaky with multi-tab (title may not be Meet); accept imperfect coverage or add AX later
• Slack: only huddle-shaped UI, not every Slack window
• While already recording: suppress prompts

B. Optional mic-activity gate

AND window match with “known meeting app is a Core Audio client.” Reduces false positives; end detection becomes “window gone OR mic released for >T.” Harder and more brittle across OS versions — treat as v2.

C. Optional calendar

Nice for “meeting in 2 minutes”; orthogonal to ad-hoc huddle detection. Don’t block awareness work on EventKit.

Prompt surface — pick one

┌───────────────────────────────────┬─────────────────────────────────────┬────────────────────────────────────────────┬──────────────────┐
│ Option │ Pros │ Cons │ Quill fit │
├───────────────────────────────────┼─────────────────────────────────────┼────────────────────────────────────────────┼──────────────────┤
│ 1. Floating NSPanel banner (“Zoom │ Action buttons; works from single │ You already reverted a recording overlay │ Best first │
│ meeting — Start recording”) │ binary; same pattern as the old │ once — keep this ephemeral prompt, not │ │
│ │ overlay pill │ always-on chrome │ │
├───────────────────────────────────┼─────────────────────────────────────┼────────────────────────────────────────────┼──────────────────┤
│ 2. Real UNUserNotification + │ Native Notification Center │ Wants proper app identity/bundle; │ Later if you re- │
│ action │ │ LaunchAgent attribution; more packaging │ bundle │
├───────────────────────────────────┼─────────────────────────────────────┼────────────────────────────────────────────┼──────────────────┤
│ 3. Menu-bar badge + menu item │ Zero new UI surface │ Easy to miss mid-join │ Good as │
│ │ │ │ fallback, not │
│ │ │ │ primary │
└───────────────────────────────────┴─────────────────────────────────────┴────────────────────────────────────────────┴──────────────────┘

Wire the panel’s primary action to existing AppController.toggle() / startSession(). Secondary: Dismiss (snooze signature).

End detection (v1.5)

When a session is live and originated from a detected meeting:

• Poll until matching signal disappears for ~15–30s → optional “Meeting ended — Stop recording?”  
• Or auto-stop with a notification (product choice; Granola-style auto-stop is convenient and also merges back-to-back calls if mic never drops)

Keep manual stop as the always-correct path.

Permissions story (doctor + README)

You already require Screen & System Audio Recording for capture. Document:

• Same permission enables window-title meeting detection  
• No new TCC for the basic path  
• Accessibility only if you later deepen Slack/Meet AX heuristics  
• Calendar only if you add scheduled prompts

───

Implementation plan for this repo

Phased, small commits:

1. MeetingWatcher — pure scanner + signatures + debounce/state machine; unit-testable with fixture window lists
2. Wire into AppController — start watcher with daemon; log detections to stderr
3. Prompt panel — Start / Dismiss; only when not recording
4. Config — meeting_detection.enabled, platform allowlist, snooze minutes
5. (Optional) end-of-meeting prompt; calendar path; AX for Meet multi-tab

Do not

• Auto-record without explicit user action (unless you add an explicit opt-in later)  
• Treat “Zoom is open” as “in a meeting”  
• Depend on a browser extension for v1 (violates single-binary ethos)  
• Reintroduce a persistent always-on overlay; prompt-only

───

Decision ledger

┌────────────────────────────────────────┬────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Decision │ Why │
├────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Primary signal: window/process │ What Mem/Monologue-class tools use for ad-hoc; no partner APIs; reuses existing Screen │
│ heuristics │ Recording TCC │
├────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Prompt, don’t auto-start │ Matches competitor UX + consent model │
├────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────┤
│ NSPanel over osascript for the banner │ Need an action button; current notify path can’t do that without rebundling │
├────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Calendar / mic-activity as secondary │ Valuable but not required for “huddle just started” │
└────────────────────────────────────────┴────────────────────────────────────────────────────────────────────────────────────────────────┘

Closed doors: joining as a bot participant; reverse-engineering Zoom’s internal IPC; relying only on calendar.

Invariant: detection never captures audio by itself; only the existing RecordingSession path records.

───

Status / next

This is design only — no code on feat/meeting-start-awareness yet. If you want implementation next, natural first PR is MeetingWatcher + stderr logging + config flag, then the Start/Dismiss panel wired to startSession().

Validation once built: join Zoom test meeting, Slack huddle, Meet in Chrome; confirm prompt appears only after debounce; Dismiss snoozes; Start produces the usual two-track session; no prompt while already recording.
