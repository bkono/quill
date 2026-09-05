import AppKit

/// Short-lived, actionable banner for the single-binary accessory app. This is
/// deliberately not a persistent recording overlay and does not activate Quill
/// or take keyboard focus away from the meeting application.
@MainActor
final class MeetingPromptController: NSObject {
    private struct Presentation {
        let eyebrow: String
        let title: String
        let body: String
        let actionTitle: String
        let actionHelp: String
        let symbolName: String
        let accentColor: NSColor
    }

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var currentPrompt: MeetingPrompt?
    private var onAction: ((UInt64, MeetingPromptAction) -> Void)?
    private var onDismiss: ((UInt64) -> Void)?

    @discardableResult
    func show(
        prompt: MeetingPrompt,
        onAction: @escaping (UInt64, MeetingPromptAction) -> Void,
        onDismiss: @escaping (UInt64) -> Void
    ) -> Bool {
        close()

        guard let screen = Self.presentationScreen() else { return false }

        let presentation = Self.presentation(for: prompt)
        let width: CGFloat = 460
        let height: CGFloat = 136
        let margin: CGFloat = 20
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

        // Do not derive the banner's contrast from whatever happens to be
        // behind it. The popover material and adaptive base color give the
        // semantic label colors a predictable light/dark-mode surface.
        let content = MeetingPromptSurfaceView(frame: NSRect(origin: .zero, size: frame.size))

        let accentRail = AdaptiveFillView(frame: NSRect(x: 0, y: 0, width: 5, height: height))
        accentRail.fillColor = presentation.accentColor
        content.addSubview(accentRail)

        let iconBackground = AdaptiveFillView(frame: NSRect(x: 20, y: 66, width: 48, height: 48))
        iconBackground.fillColor = presentation.accentColor.withAlphaComponent(0.18)
        iconBackground.layer?.cornerRadius = 14
        iconBackground.layer?.cornerCurve = .continuous
        content.addSubview(iconBackground)

        let icon = NSImageView(frame: NSRect(x: 11, y: 11, width: 26, height: 26))
        icon.image = NSImage(
            systemSymbolName: presentation.symbolName,
            accessibilityDescription: presentation.eyebrow
        ) ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: presentation.eyebrow)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        icon.contentTintColor = presentation.accentColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        iconBackground.addSubview(icon)

        let eyebrow = NSTextField(labelWithString: presentation.eyebrow)
        eyebrow.font = .systemFont(ofSize: 10, weight: .bold)
        eyebrow.textColor = Self.eyebrowTextColor(accent: presentation.accentColor)
        eyebrow.frame = NSRect(x: 84, y: 109, width: 320, height: 14)
        content.addSubview(eyebrow)

        let title = NSTextField(labelWithString: presentation.title)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 84, y: 82, width: 328, height: 22)
        content.addSubview(title)

        let body = NSTextField(labelWithString: presentation.body)
        body.font = .systemFont(ofSize: 13, weight: .regular)
        body.textColor = .secondaryLabelColor
        body.lineBreakMode = .byTruncatingTail
        body.frame = NSRect(x: 84, y: 59, width: 348, height: 19)
        content.addSubview(body)

        let actionButton = BannerButton(
            title: presentation.actionTitle,
            style: .primary(presentation.accentColor),
            target: self,
            action: #selector(actionClicked)
        )
        actionButton.frame = NSRect(x: 84, y: 14, width: 156, height: 36)
        actionButton.toolTip = presentation.actionHelp
        actionButton.setAccessibilityHelp(presentation.actionHelp)
        content.addSubview(actionButton)

        let notNowButton = BannerButton(
            title: "Not now",
            style: .secondary,
            target: self,
            action: #selector(dismissClicked)
        )
        notNowButton.frame = NSRect(x: 248, y: 14, width: 88, height: 36)
        notNowButton.toolTip = "Dismiss this prompt"
        notNowButton.setAccessibilityHelp("Dismiss this prompt without changing recording state")
        content.addSubview(notNowButton)

        let dismissButton = NSButton(
            title: "×",
            target: self,
            action: #selector(dismissClicked)
        )
        dismissButton.frame = NSRect(x: width - 42, y: height - 42, width: 30, height: 30)
        dismissButton.isBordered = false
        dismissButton.refusesFirstResponder = true
        dismissButton.focusRingType = .none
        dismissButton.font = .systemFont(ofSize: 18, weight: .medium)
        dismissButton.contentTintColor = .secondaryLabelColor
        dismissButton.toolTip = "Dismiss this prompt"
        dismissButton.setAccessibilityLabel("Dismiss meeting prompt")
        content.addSubview(dismissButton)

        panel.contentView = content
        panel.setAccessibilityLabel(presentation.title)

        self.panel = panel
        currentPrompt = prompt
        self.onAction = onAction
        self.onDismiss = onDismiss

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }

        dismissTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.dismissCurrent() }
        }
        return true
    }

    /// Close without changing the media session's suppression state. Used when
    /// recording state changes, evidence returns, or Quill shuts down.
    func close() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.close()
        panel = nil
        currentPrompt = nil
        onAction = nil
        onDismiss = nil
    }

    @objc private func actionClicked() {
        guard let prompt = currentPrompt else { return }
        let action = onAction
        close()
        action?(prompt.token, prompt.action)
    }

    @objc private func dismissClicked() {
        dismissCurrent()
    }

    private func dismissCurrent() {
        guard let prompt = currentPrompt else { return }
        let action = onDismiss
        close()
        action?(prompt.token)
    }

    private static func presentation(for prompt: MeetingPrompt) -> Presentation {
        switch prompt.action {
        case .startRecording:
            Presentation(
                eyebrow: "MEETING DETECTED",
                title: "\(prompt.candidate.displayName) call detected",
                body: "Record microphone and system audio as separate tracks.",
                actionTitle: "Start Recording",
                actionHelp: "Start a new Quill recording",
                symbolName: "record.circle",
                accentColor: .systemBlue
            )
        case .stopRecording:
            Presentation(
                eyebrow: "RECORDING STILL ACTIVE",
                title: "\(prompt.candidate.displayName) call may have ended",
                body: "Stop recording and begin transcription?",
                actionTitle: "Stop Recording",
                actionHelp: "Stop the current Quill recording",
                symbolName: "stop.circle.fill",
                accentColor: .systemRed
            )
        }
    }

    /// 10-pt `systemBlue`/`systemRed` fail contrast on a light window
    /// background. Darken the accent in light appearance only; keep the
    /// recognizable hue in dark mode. Decorative chrome still uses the raw
    /// accent.
    private static func eyebrowTextColor(accent: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let resolved = accent.resolvedColor(with: appearance)
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if isDark {
                return resolved
            }
            return resolved.blended(withFraction: 0.38, of: .black) ?? resolved
        }
    }

    private static func presentationScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

@MainActor
private final class BannerButton: NSButton {
    enum Style {
        case primary(NSColor)
        case secondary
    }

    private let style: Style
    private var trackingAreaReference: NSTrackingArea?
    private var isPointerInside = false

    init(
        title: String,
        style: Style,
        target: AnyObject?,
        action: Selector?
    ) {
        self.style = style
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        refusesFirstResponder = true
        focusRingType = .none
        font = .systemFont(ofSize: 13, weight: .semibold)
        switch style {
        case .primary:
            contentTintColor = .white
        case .secondary:
            contentTintColor = .labelColor
        }
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        updateBackground()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        updateBackground()
    }

    override func mouseDown(with event: NSEvent) {
        updateBackground(isPressed: true)
        super.mouseDown(with: event)
        updateBackground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    override func updateLayer() {
        super.updateLayer()
        updateBackground()
    }

    private func updateBackground(isPressed: Bool = false) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor
            switch style {
            case .primary(let accent):
                // System red and blue are too bright for small white type in some
                // appearances. A darker solid fill keeps the action readable.
                let base = accent.blended(withFraction: 0.18, of: .black) ?? accent
                color = base.withAlphaComponent(isPressed ? 0.78 : isPointerInside ? 0.9 : 1)
            case .secondary:
                color = NSColor.labelColor.withAlphaComponent(
                    isPressed ? 0.18 : isPointerInside ? 0.13 : 0.08
                )
            }
            layer?.backgroundColor = color.cgColor
        }
    }
}

/// Popover surface whose layer fill and border re-resolve when the effective
/// appearance changes. Snapshotting `NSColor.cgColor` at build time would
/// otherwise freeze a light or dark fill while semantic text colors update.
@MainActor
private final class MeetingPromptSurfaceView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        applyLayerColors()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerColors()
    }

    override func updateLayer() {
        super.updateLayer()
        applyLayerColors()
    }

    private func applyLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(0.94)
                .cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

/// Solid fill that re-resolves its `NSColor` against the current appearance
/// instead of keeping a one-shot `CGColor` snapshot.
@MainActor
private final class AdaptiveFillView: NSView {
    var fillColor: NSColor? {
        didSet { applyLayerColors() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerColors()
    }

    override func updateLayer() {
        super.updateLayer()
        applyLayerColors()
    }

    private func applyLayerColors() {
        guard let fillColor else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fillColor.cgColor
        }
    }
}
