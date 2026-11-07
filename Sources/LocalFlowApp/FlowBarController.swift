import AppKit
import Combine
import CoreGraphics
import LocalFlowCore

enum FlowBarMode {
    case idle
    case listening
    case command
    case handsFree
    case commandHandsFree
    case processing
    case meeting
    case notice
}

/// Fixed transparent panel; only the pill inside it is visible and interactive.
private let flowBarPanelSize = NSSize(width: 360, height: 48)
private let flowBarPillBottomInset: CGFloat = 6
private let flowBarIdlePillSize = NSSize(width: 44, height: 10)
private let flowBarHoverPillSize = NSSize(width: 260, height: 30)
private let flowBarMeetingPillSize = NSSize(width: 150, height: 30)
private let flowBarMeetingHoverPillSize = NSSize(width: 320, height: 42)

/// Wispr-style floating pill shown while dictating. Pure AppKit, never activates.
/// The panel itself never resizes: the pill layer animates inside it, which keeps
/// mouse tracking stable (no tracking-area churn while the frame animates).
@MainActor
final class FlowBarController: NSObject {
    private let session: DictationSession
    private let meeting: MeetingSession?
    private let settings: Settings

    private var panel: FlowBarPanel!
    private var barView: FlowBarView!
    private var displayTimer: Timer?
    private var mouseTimer: Timer?
    private var screenTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private var currentScreen: NSScreen?
    private var targetFrame = NSRect.zero

    private var displayedPillSize = flowBarIdlePillSize
    private var pillFrom = flowBarIdlePillSize
    private var pillTo = flowBarIdlePillSize
    private var pillAnimStart = Date.distantPast
    private static let pillAnimDuration: TimeInterval = 0.15

    private var smoothedLevel: CGFloat = 0
    private var meetingSmoothed = [CGFloat](repeating: 0, count: 2)
    private var pulse: CGFloat = 0
    private var barLevels = [CGFloat](repeating: 0.12, count: 9)

    private var hoverInsideSince: Date?
    private var hoverOutsideSince: Date?

    init(session: DictationSession, meeting: MeetingSession? = nil, settings: Settings) {
        self.session = session
        self.meeting = meeting
        self.settings = settings
        super.init()
    }

    func start() {
        let panel = FlowBarPanel(
            contentRect: NSRect(origin: .zero, size: flowBarPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true

        let view = FlowBarView(frame: NSRect(origin: .zero, size: flowBarPanelSize))
        view.onActivate = { [weak self] in Task { @MainActor in self?.activateFromBar() } }
        view.onCancel = { [weak self] in Task { @MainActor in self?.session.cancelDictation() } }
        view.onStop = { [weak self] in Task { @MainActor in self?.session.requestStop() } }
        view.onMeetingStop = { [weak self] in Task { @MainActor in await self?.meeting?.stop() } }
        panel.contentView = view
        self.panel = panel
        self.barView = view

        repositionIfNeeded(reason: "launch")
        panel.orderFrontRegardless()
        update()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(workspaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(workspaceChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollHover() }
        }
        screenTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.repositionIfNeeded(reason: "timer") }
        }

        session.$state.sink { [weak self] _ in Task { @MainActor in self?.update() } }.store(in: &cancellables)
        session.$isHandsFree.sink { [weak self] _ in Task { @MainActor in self?.update() } }.store(in: &cancellables)
        session.$isCommandMode.sink { [weak self] _ in Task { @MainActor in self?.update() } }.store(in: &cancellables)
        session.$notice.sink { [weak self] _ in Task { @MainActor in self?.update() } }.store(in: &cancellables)
        meeting?.$state.sink { [weak self] _ in Task { @MainActor in self?.update() } }.store(in: &cancellables)
        meeting?.$elapsed.sink { [weak self] _ in Task { @MainActor in self?.update() } }.store(in: &cancellables)
        meeting?.$notice.sink { [weak self] _ in Task { @MainActor in self?.update() } }.store(in: &cancellables)
        meeting?.$lastLine.sink { [weak self] _ in Task { @MainActor in self?.update() } }.store(in: &cancellables)
        settings.$showFlowBar.sink { [weak self] _ in Task { @MainActor in self?.update() } }.store(in: &cancellables)
        settings.$triggerKey.sink { [weak self] _ in Task { @MainActor in self?.update() } }.store(in: &cancellables)
    }

    func stop() {
        displayTimer?.invalidate()
        displayTimer = nil
        mouseTimer?.invalidate()
        mouseTimer = nil
        screenTimer?.invalidate()
        screenTimer = nil
        NotificationCenter.default.removeObserver(self)
        panel?.orderOut(nil)
        cancellables.removeAll()
    }

    // MARK: - Mode and sizing

    /// The notice currently worth showing: a live meeting takes precedence, then
    /// meeting notices (suggestions, save confirmations), then dictation notices.
    private var activeNotice: String? {
        if let meeting, meeting.isRecording { return nil }
        if let meeting, meeting.notice != nil { return meeting.notice }
        return session.notice
    }

    private var mode: FlowBarMode {
        if let meeting {
            if meeting.isRecording { return .meeting }
            switch meeting.state {
            case .starting, .finishing: return .processing
            case .error: break
            case .idle, .recording: break
            }
        }
        if activeNotice != nil { return .notice }
        switch session.state {
        case .idle, .error:
            return .idle
        case .warming, .transcribing, .cleaning, .inserting:
            return .processing
        case .listening:
            if session.isCommandMode {
                return session.isHandsFree ? .commandHandsFree : .command
            }
            return session.isHandsFree ? .handsFree : .listening
        }
    }

    private var animatingMode: Bool {
        switch mode {
        case .listening, .command, .handsFree, .commandHandsFree, .processing, .meeting:
            return true
        case .idle, .notice:
            return false
        }
    }

    private var desiredSize: NSSize {
        switch mode {
        case .idle:
            return barView.isHovering ? flowBarHoverPillSize : flowBarIdlePillSize
        case .listening:
            return NSSize(width: 110, height: 30)
        case .command:
            return NSSize(width: 160, height: 30)
        case .handsFree:
            return NSSize(width: 170, height: 30)
        case .commandHandsFree:
            return NSSize(width: 220, height: 30)
        case .processing:
            return NSSize(width: 70, height: 30)
        case .meeting:
            return barView.isHovering ? flowBarMeetingHoverPillSize : flowBarMeetingPillSize
        case .notice:
            return noticeSize()
        }
    }

    private func noticeSize() -> NSSize {
        guard let text = activeNotice, !text.isEmpty else {
            return NSSize(width: 70, height: 30)
        }
        let font = NSFont.systemFont(ofSize: 11)
        let measured = (text as NSString).size(withAttributes: [.font: font])
        let width = min(340, max(70, measured.width + 30))
        return NSSize(width: width, height: 30)
    }

    private func update() {
        let newMode = mode
        let size = desiredSize
        if size != pillTo {
            pillFrom = displayedPillSize
            pillTo = size
            pillAnimStart = Date()
        }
        barView.pillSize = displayedPillSize
        barView.configure(
            mode: newMode,
            notice: activeNotice,
            hint: hintText,
            meetingLine: meeting?.lastLine ?? "",
            activateEnabled: newMode == .idle || (meeting?.noticeAction != nil && newMode == .notice)
        )
        updatePanelVisibility()
        updateDisplayTimer()
        updateMousePassthrough()
    }

    private var hintText: String {
        let key = settings.triggerKey.shortName
        return "Hold \(key) to dictate · double-tap \(key) for hands-free"
    }

    private func updatePanelVisibility() {
        let visible = settings.showFlowBar || mode != .idle
        if visible && !panel.isVisible {
            panel.orderFrontRegardless()
        } else if !visible && panel.isVisible {
            panel.orderOut(nil)
        }
    }

    // MARK: - Frame animation (pill only; the panel never moves for state changes)

    private var pillSettled: Bool { displayedPillSize == pillTo }

    private func updateDisplayTimer() {
        let needs = animatingMode || !pillSettled
        if needs && displayTimer == nil {
            displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } else if !needs, displayTimer != nil {
            displayTimer?.invalidate()
            displayTimer = nil
        }
    }

    private func tick() {
        advancePill()
        if animatingMode {
            if mode == .meeting, let meeting {
                pulse += 0.45
                barView.meetingMeterView.levelsMe = meetingMeterLevel(meeting.meLevel, slot: 0)
                barView.meetingMeterView.levelsThem = meetingMeterLevel(meeting.themLevel, slot: 1)
                barView.meetingMeterView.needsDisplay = true
                if case .recording(let startedAt) = meeting.state {
                    barView.timerText = Self.formatElapsed(since: startedAt)
                }
            } else {
                let target = min(1, CGFloat(session.level) * 12)
                if target > smoothedLevel {
                    smoothedLevel += (target - smoothedLevel) * 0.5
                } else {
                    smoothedLevel += (target - smoothedLevel) * 0.15
                }
                pulse += 0.45
                for i in 0..<barLevels.count {
                    let wobble = 0.55 + 0.45 * abs(sin(pulse * 0.8 + CGFloat(i) * 0.9))
                    barLevels[i] = max(0.05, smoothedLevel * wobble)
                }
                barView.waveformView.levels = barLevels
                barView.waveformView.phase = pulse
                barView.dotsView.pulse = pulse
                if case .listening(let startedAt) = session.state {
                    barView.timerText = Self.formatElapsed(since: startedAt)
                }
                barView.waveformView.needsDisplay = true
                barView.dotsView.needsDisplay = true
            }
        }
        updateDisplayTimer()
    }

    /// Meeting levels arrive as per-buffer RMS; scale and smooth them per lane.
    private func meetingMeterLevel(_ rms: Float, slot: Int) -> [CGFloat] {
        let target = min(1, CGFloat(rms) * 18)
        meetingSmoothed[slot] += (target - meetingSmoothed[slot]) * (target > meetingSmoothed[slot] ? 0.5 : 0.2)
        let level = meetingSmoothed[slot]
        return (0..<5).map { i in
            let wobble = 0.6 + 0.4 * abs(sin(pulse + CGFloat(i) * 1.3 + CGFloat(slot)))
            return max(0.04, level * wobble)
        }
    }

    private func advancePill() {
        let t = min(1, Date().timeIntervalSince(pillAnimStart) / Self.pillAnimDuration)
        let eased = t * t * (3 - 2 * t)
        displayedPillSize = NSSize(
            width: pillFrom.width + (pillTo.width - pillFrom.width) * eased,
            height: pillFrom.height + (pillTo.height - pillFrom.height) * eased
        )
        if t >= 1 { displayedPillSize = pillTo }
        barView.pillSize = displayedPillSize
        barView.needsLayout = true
    }

    private static func formatElapsed(since date: Date) -> String {
        let elapsed = max(0, Int(Date().timeIntervalSince(date)))
        return String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }

    // MARK: - Hover (polled; no tracking areas so the fixed panel can't flicker)

    /// Current on-screen rect of the pill, in screen coordinates.
    private func pillScreenRect(size: NSSize) -> NSRect {
        let frame = panel.frame
        return NSRect(
            x: frame.midX - size.width / 2,
            y: frame.minY + flowBarPillBottomInset,
            width: size.width,
            height: size.height
        )
    }

    private func pollHover() {
        guard panel.isVisible else {
            hoverInsideSince = nil
            hoverOutsideSince = nil
            if barView.isHovering {
                barView.isHovering = false
                update()
            }
            updateMousePassthrough()
            return
        }

        let mouse = NSEvent.mouseLocation
        let now = Date()

        let hoverable = (mode == .idle || mode == .meeting)
        if hoverable {
            if barView.isHovering {
                let exitSize: NSSize = (mode == .idle) ? flowBarHoverPillSize : flowBarMeetingHoverPillSize
                let expanded = pillScreenRect(size: exitSize).insetBy(dx: -8, dy: -8)
                if expanded.contains(mouse) {
                    hoverOutsideSince = nil
                } else {
                    if hoverOutsideSince == nil { hoverOutsideSince = now }
                    if now.timeIntervalSince(hoverOutsideSince!) >= 0.30 {
                        barView.isHovering = false
                        hoverOutsideSince = nil
                        hoverInsideSince = nil
                        update()
                    }
                }
            } else {
                let enterSize: NSSize = (mode == .idle) ? flowBarIdlePillSize : flowBarMeetingPillSize
                let idle = pillScreenRect(size: enterSize).insetBy(dx: -6, dy: -6)
                if idle.contains(mouse) {
                    if hoverInsideSince == nil { hoverInsideSince = now }
                    if now.timeIntervalSince(hoverInsideSince!) >= 0.12 {
                        barView.isHovering = true
                        hoverInsideSince = nil
                        update()
                    }
                } else {
                    hoverInsideSince = nil
                }
            }
        } else {
            hoverInsideSince = nil
            hoverOutsideSince = nil
            if barView.isHovering {
                barView.isHovering = false
            }
        }

        updateMousePassthrough()
    }

    /// The fixed panel is mostly transparent; only let it receive mouse events
    /// while the cursor is actually over the pill.
    private func updateMousePassthrough() {
        let rect = pillScreenRect(size: displayedPillSize).insetBy(dx: -6, dy: -6)
        panel.ignoresMouseEvents = !rect.contains(NSEvent.mouseLocation)
    }

    // MARK: - Positioning

    private func activateFromBar() {
        if let meeting, meeting.noticeAction != nil {
            meeting.activateNotice()
            return
        }
        Task { await session.startDictation() }
    }

    private func screenAtMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func dockAutoHidden() -> Bool {
        UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
    }

    /// True when the frontmost app owns an on-screen window covering this screen's
    /// full frame (menu bar included) — i.e. a fullscreen space.
    private func frontmostFullscreen(on screen: NSScreen) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = app.processIdentifier
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        guard let mainHeight = NSScreen.screens.first?.frame.height, mainHeight > 0 else { return false }
        // CGWindowList bounds are top-left-origin global points; convert the screen frame.
        let sf = screen.frame
        let cgScreen = CGRect(x: sf.minX, y: mainHeight - sf.maxY, width: sf.width, height: sf.height)
        for window in windows {
            guard (window["kCGWindowOwnerPID"] as? NSNumber)?.int32Value == pid,
                  (window["kCGWindowLayer"] as? NSNumber)?.intValue == 0,
                  let boundsDict = window["kCGWindowBounds"] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            // Fullscreen windows on notched displays start below the notch/menu-bar band,
            // so match width + bottom edge and allow the top to sit within that band.
            let topBand = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness) + 6
            if abs(rect.minX - cgScreen.minX) < 3,
               abs(rect.width - cgScreen.width) < 3,
               abs(rect.maxY - cgScreen.maxY) < 3,
               rect.minY - cgScreen.minY <= topBand {
                return true
            }
        }
        return false
    }

    /// Sits just above the Dock when it is visible; drops to the bottom edge when the
    /// Dock auto-hides or the frontmost app is fullscreen.
    private func repositionIfNeeded(reason: String) {
        guard let screen = screenAtMouse() else { return }
        let fullscreen = frontmostFullscreen(on: screen)
        let dockHidden = dockAutoHidden()
        let pillBottomY = (fullscreen || dockHidden)
            ? screen.frame.minY + 8
            : screen.visibleFrame.minY + 10
        let origin = NSPoint(
            x: screen.frame.midX - flowBarPanelSize.width / 2,
            y: pillBottomY - flowBarPillBottomInset
        )
        let target = NSRect(origin: origin, size: flowBarPanelSize)
        guard target != targetFrame || screen != currentScreen else { return }

        let firstPlacement = targetFrame == .zero
        let oldMinY = firstPlacement ? panel.frame.minY : targetFrame.minY
        currentScreen = screen
        targetFrame = target
        if firstPlacement {
            panel.setFrame(target, display: false)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        }
        LocalFlowLog.write(
            "flowbar: move (\(reason)) y \(Int(oldMinY)) -> \(Int(target.minY)) " +
            "screen=\(screen.localizedName) fullscreen=\(fullscreen) dockAutoHidden=\(dockHidden)"
        )
    }

    @objc private func screenParametersChanged() {
        repositionIfNeeded(reason: "screens")
    }

    @objc private func workspaceChanged() {
        repositionIfNeeded(reason: "workspace")
    }
}

// MARK: - Panel

final class FlowBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Content view

final class FlowBarView: NSView {
    var onActivate: (() -> Void)?
    var onCancel: (() -> Void)?
    var onStop: (() -> Void)?
    var onMeetingStop: (() -> Void)?

    var isHovering = false
    var allowsActivation = false
    var pillSize = flowBarIdlePillSize

    let pillBackground = NSView()
    let waveformView = WaveformBarView()
    let dotsView = PulsingDotsView()
    let meetingMeterView = MeetingMeterView()
    let meetingLineLabel = NSTextField(labelWithString: "")
    let redDot = NSView()
    let timerLabel = NSTextField(labelWithString: "0:00")
    let commandLabel = NSTextField(labelWithString: "Command")
    let hintLabel = NSTextField(labelWithString: "")
    let noticeLabel = NSTextField(labelWithString: "")
    let cancelButton = NSButton(title: "", target: nil, action: nil)
    let stopButton = NSButton(title: "", target: nil, action: nil)
    let meetingStopButton = NSButton(title: "", target: nil, action: nil)

    var timerText: String = "0:00" {
        didSet { timerLabel.stringValue = timerText }
    }

    private var mode: FlowBarMode = .idle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        pillBackground.wantsLayer = true
        pillBackground.layer?.backgroundColor = NSColor(
            srgbRed: 0x11 / 255.0, green: 0x11 / 255.0, blue: 0x11 / 255.0, alpha: 0.92
        ).cgColor
        pillBackground.layer?.borderWidth = 1
        pillBackground.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        pillBackground.layer?.shadowColor = NSColor.black.cgColor
        pillBackground.layer?.shadowOpacity = 0.4
        pillBackground.layer?.shadowRadius = 10
        pillBackground.layer?.shadowOffset = CGSize(width: 0, height: -3)
        addSubview(pillBackground)

        waveformView.isHidden = true
        addSubview(waveformView)

        dotsView.isHidden = true
        addSubview(dotsView)

        meetingMeterView.isHidden = true
        addSubview(meetingMeterView)

        meetingLineLabel.font = .systemFont(ofSize: 10)
        meetingLineLabel.textColor = NSColor(white: 0.85, alpha: 0.95)
        meetingLineLabel.alignment = .left
        meetingLineLabel.isBezeled = false
        meetingLineLabel.drawsBackground = false
        meetingLineLabel.isEditable = false
        meetingLineLabel.isSelectable = false
        meetingLineLabel.maximumNumberOfLines = 1
        meetingLineLabel.lineBreakMode = .byTruncatingTail
        meetingLineLabel.isHidden = true
        addSubview(meetingLineLabel)

        redDot.wantsLayer = true
        redDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        redDot.layer?.cornerRadius = 4
        redDot.isHidden = true
        addSubview(redDot)

        for label in [timerLabel, commandLabel, hintLabel, noticeLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .white
            label.alignment = .center
            label.isBezeled = false
            label.drawsBackground = false
            label.isEditable = false
            label.isSelectable = false
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.isHidden = true
            addSubview(label)
        }
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        commandLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        commandLabel.textColor = NSColor(srgbRed: 0.62, green: 0.45, blue: 1.0, alpha: 0.95)

        configureButton(cancelButton, symbol: "xmark", action: #selector(cancelTapped))
        configureButton(stopButton, symbol: "checkmark", action: #selector(stopTapped))
        cancelButton.isHidden = true
        stopButton.isHidden = true
        addSubview(cancelButton)
        addSubview(stopButton)

        configureButton(meetingStopButton, symbol: "stop.fill", action: #selector(meetingStopTapped))
        meetingStopButton.isHidden = true
        addSubview(meetingStopButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configureButton(_ button: NSButton, symbol: String, action: Selector) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        button.contentTintColor = NSColor(white: 0.88, alpha: 0.95)
        button.imageScaling = .scaleProportionallyDown
        button.focusRingType = .none
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @objc private func cancelTapped() { onCancel?() }
    @objc private func stopTapped() { onStop?() }
    @objc private func meetingStopTapped() { onMeetingStop?() }

    func configure(mode newMode: FlowBarMode, notice: String?, hint: String, meetingLine: String = "", activateEnabled: Bool = false) {
        mode = newMode
        let isCommand = (newMode == .command || newMode == .commandHandsFree)
        let isListeningLike = (newMode == .listening || newMode == .command ||
                               newMode == .handsFree || newMode == .commandHandsFree)
        let hasControls = (newMode == .handsFree || newMode == .commandHandsFree)

        waveformView.isHidden = !isListeningLike
        waveformView.tint = isCommand
            ? NSColor(srgbRed: 0.62, green: 0.45, blue: 1.0, alpha: 0.95)
            : NSColor(white: 0.92, alpha: 0.95)
        redDot.isHidden = !(newMode == .listening || newMode == .command || newMode == .meeting)
        timerLabel.isHidden = !(isListeningLike || newMode == .meeting)
        commandLabel.isHidden = !isCommand
        dotsView.isHidden = (newMode != .processing)
        meetingMeterView.isHidden = (newMode != .meeting)
        meetingLineLabel.isHidden = !(newMode == .meeting && isHovering)
        meetingLineLabel.stringValue = meetingLine
        noticeLabel.isHidden = (newMode != .notice)
        hintLabel.isHidden = !(newMode == .idle && isHovering)
        cancelButton.isHidden = !hasControls
        stopButton.isHidden = !hasControls
        meetingStopButton.isHidden = (newMode != .meeting)

        if newMode == .notice, let notice {
            noticeLabel.stringValue = notice
        }
        if newMode == .idle {
            hintLabel.stringValue = hint
        }
        allowsActivation = activateEnabled || (newMode == .idle)
        needsLayout = true
    }

    private var pillRect: NSRect {
        NSRect(
            x: (bounds.width - pillSize.width) / 2,
            y: flowBarPillBottomInset,
            width: pillSize.width,
            height: pillSize.height
        )
    }

    override func layout() {
        super.layout()
        let pill = pillRect
        pillBackground.frame = pill
        pillBackground.layer?.cornerRadius = pill.height / 2
        pillBackground.layer?.shadowPath = CGPath(
            roundedRect: pillBackground.bounds,
            cornerWidth: pill.height / 2,
            cornerHeight: pill.height / 2,
            transform: nil
        )

        switch mode {
        case .idle:
            hintLabel.frame = pill.insetBy(dx: 12, dy: 0)
        case .notice:
            noticeLabel.frame = pill.insetBy(dx: 12, dy: 0)
        case .processing:
            centerRow(in: pill, [(dotsView, 36, 10)])
        case .listening:
            centerRow(in: pill, [(redDot, 8, 8), (waveformView, 44, 24), (timerLabel, 36, 14)])
        case .command:
            centerRow(in: pill, [(redDot, 8, 8), (commandLabel, 46, 14), (waveformView, 44, 24), (timerLabel, 36, 14)])
        case .handsFree:
            centerRow(in: pill, [(cancelButton, 22, 22), (waveformView, 44, 24), (stopButton, 22, 22)])
        case .commandHandsFree:
            centerRow(in: pill, [(commandLabel, 46, 14), (cancelButton, 22, 22), (waveformView, 44, 24), (stopButton, 22, 22)])
        case .meeting:
            if isHovering {
                let rowRect = NSRect(x: pill.minX, y: pill.minY + 14, width: pill.width, height: pill.height - 16)
                centerRow(in: rowRect, [
                    (redDot, 8, 8), (meetingMeterView, 26, 20), (timerLabel, 34, 14), (meetingStopButton, 20, 20),
                ], spacing: 5)
                meetingLineLabel.frame = NSRect(
                    x: pill.minX + 12,
                    y: pill.minY + 2,
                    width: pill.width - 24,
                    height: 12
                )
            } else {
                centerRow(in: pill, [
                    (redDot, 8, 8), (meetingMeterView, 30, 22), (timerLabel, 36, 14), (meetingStopButton, 22, 22),
                ], spacing: 6)
            }
        }
    }

    private func centerRow(in rect: NSRect, _ items: [(NSView, CGFloat, CGFloat)], spacing: CGFloat = 6) {
        let total = items.reduce(0) { $0 + $1.1 } + spacing * CGFloat(max(0, items.count - 1))
        var x = rect.minX + (rect.width - total) / 2
        for (view, width, height) in items {
            view.frame = NSRect(x: x, y: rect.minY + (rect.height - height) / 2, width: width, height: height)
            x += width + spacing
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard allowsActivation else { return }
        onActivate?()
    }
}

// MARK: - Waveform

final class WaveformBarView: NSView {
    var levels: [CGFloat] = Array(repeating: 0.12, count: 9)
    var phase: CGFloat = 0
    var tint: NSColor = .white

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let barCount = levels.count
        let barWidth: CGFloat = 3
        let spacing: CGFloat = 2
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        let x0 = (bounds.width - totalWidth) / 2
        let maxHeight = bounds.height - 2
        context.setFillColor(tint.cgColor)
        for (index, level) in levels.enumerated() {
            let height = max(2.5, level * maxHeight)
            let rect = CGRect(
                x: x0 + CGFloat(index) * (barWidth + spacing),
                y: (bounds.height - height) / 2,
                width: barWidth,
                height: height
            )
            let path = CGPath(roundedRect: rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
            context.addPath(path)
            context.fillPath()
        }
    }
}

/// Two-lane level meter for meeting mode: top lane = Me (mic), bottom = Them
/// (system audio). Each lane is a row of small bars.
final class MeetingMeterView: NSView {
    var levelsMe: [CGFloat] = Array(repeating: 0.05, count: 5)
    var levelsThem: [CGFloat] = Array(repeating: 0.05, count: 5)

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let barWidth: CGFloat = 2.5
        let spacing: CGFloat = 2
        let laneHeight: CGFloat = 8
        let laneGap: CGFloat = 3
        let totalWidth = 5 * barWidth + 4 * spacing
        let x0 = (bounds.width - totalWidth) / 2
        let meColor = NSColor(srgbRed: 0.35, green: 0.75, blue: 1.0, alpha: 0.95).cgColor
        let themColor = NSColor(srgbRed: 1.0, green: 0.55, blue: 0.35, alpha: 0.95).cgColor

        drawLane(context, levels: levelsMe, color: meColor, x0: x0, y: bounds.midY + laneGap / 2, barWidth: barWidth, spacing: spacing, laneHeight: laneHeight)
        drawLane(context, levels: levelsThem, color: themColor, x0: x0, y: bounds.midY - laneGap / 2 - laneHeight, barWidth: barWidth, spacing: spacing, laneHeight: laneHeight)
    }

    private func drawLane(_ context: CGContext, levels: [CGFloat], color: CGColor, x0: CGFloat, y: CGFloat, barWidth: CGFloat, spacing: CGFloat, laneHeight: CGFloat) {
        context.setFillColor(color)
        for (index, level) in levels.enumerated() {
            let h = max(1.5, level * laneHeight)
            let rect = CGRect(
                x: x0 + CGFloat(index) * (barWidth + spacing),
                y: y + (laneHeight - h) / 2,
                width: barWidth,
                height: h
            )
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
        }
    }
}

// MARK: - Processing dots

final class PulsingDotsView: NSView {
    var pulse: CGFloat = 0
    var tint: NSColor = .white

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dotRadius: CGFloat = 3
        let spacing: CGFloat = 8
        let totalWidth = 3 * dotRadius * 2 + 2 * spacing
        let x0 = (bounds.width - totalWidth) / 2
        let y = bounds.height / 2
        for index in 0..<3 {
            let alpha = 0.3 + 0.7 * abs(sin(pulse + CGFloat(index) * 1.1))
            let rect = CGRect(
                x: x0 + CGFloat(index) * (dotRadius * 2 + spacing),
                y: y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
            context.setFillColor(tint.withAlphaComponent(alpha).cgColor)
            context.fillEllipse(in: rect)
        }
    }
}
