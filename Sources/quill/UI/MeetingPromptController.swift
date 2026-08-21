import AppKit

/// Short-lived, actionable banner for the single-binary accessory app. This is
/// deliberately not a persistent recording overlay and does not activate Quill
/// or take keyboard focus away from the meeting application.
@MainActor
final class MeetingPromptController: NSObject {
    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var currentSessionID: UInt64?
    private var onStart: ((UInt64) -> Void)?
    private var onDismiss: ((UInt64) -> Void)?

    @discardableResult
    func show(
        prompt: MeetingPrompt,
        onStart: @escaping (UInt64) -> Void,
        onDismiss: @escaping (UInt64) -> Void
    ) -> Bool {
        close()

        guard let screen = Self.presentationScreen() else { return false }

        let width: CGFloat = 360
        let height: CGFloat = 72
        let margin: CGFloat = 16
        let visibleFrame = screen.visibleFrame
        let frame = NSRect(
            x: visibleFrame.maxX - width - margin,
            y: visibleFrame.maxY - height - margin,
            width: width,
            height: height
        )

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [
            .moveToActiveSpace,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]

        let content = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let dismissButton = NSButton(
            title: "×",
            target: self,
            action: #selector(dismissClicked)
        )
        dismissButton.frame = NSRect(x: 10, y: 40, width: 22, height: 22)
        dismissButton.isBordered = false
        dismissButton.focusRingType = .none
        dismissButton.font = .systemFont(ofSize: 15, weight: .medium)
        dismissButton.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        dismissButton.toolTip = "Dismiss for this call"
        content.addSubview(dismissButton)

        let title = NSTextField(labelWithString: "\(prompt.candidate.displayName) call detected")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 42, y: 39, width: 176, height: 19)
        content.addSubview(title)

        let body = NSTextField(labelWithString: "Start recording with quill?")
        body.font = .systemFont(ofSize: 11)
        body.textColor = NSColor.white.withAlphaComponent(0.62)
        body.frame = NSRect(x: 42, y: 19, width: 176, height: 17)
        content.addSubview(body)

        let startButton = NSButton(
            title: "Start Recording",
            target: self,
            action: #selector(startClicked)
        )
        startButton.frame = NSRect(x: width - 132, y: 20, width: 118, height: 32)
        startButton.isBordered = false
        startButton.focusRingType = .none
        startButton.font = .systemFont(ofSize: 12, weight: .semibold)
        startButton.contentTintColor = .white
        startButton.wantsLayer = true
        startButton.layer?.backgroundColor = NSColor.systemBlue.cgColor
        startButton.layer?.cornerRadius = 7
        content.addSubview(startButton)

        panel.contentView = content
        panel.orderFrontRegardless()

        self.panel = panel
        currentSessionID = prompt.sessionID
        self.onStart = onStart
        self.onDismiss = onDismiss
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.dismissCurrent() }
        }
        return true
    }

    /// Close without changing the media session's suppression state. Used when
    /// recording begins elsewhere, the candidate ends, or Quill shuts down.
    func close() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.close()
        panel = nil
        currentSessionID = nil
        onStart = nil
        onDismiss = nil
    }

    @objc private func startClicked() {
        guard let sessionID = currentSessionID else { return }
        let action = onStart
        close()
        action?(sessionID)
    }

    @objc private func dismissClicked() {
        dismissCurrent()
    }

    private func dismissCurrent() {
        guard let sessionID = currentSessionID else { return }
        let action = onDismiss
        close()
        action?(sessionID)
    }

    private static func presentationScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}
