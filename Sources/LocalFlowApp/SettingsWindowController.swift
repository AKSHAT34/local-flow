import AppKit
import LocalFlowCore

@MainActor
final class SettingsWindowController: NSObject {
    private let settings: Settings
    private let session: DictationSession
    private var window: NSWindow?

    private var micLabel = NSTextField(labelWithString: "—")
    private var speechLabel = NSTextField(labelWithString: "—")
    private var axLabel = NSTextField(labelWithString: "—")
    private var maxRecordLabel = NSTextField(labelWithString: "")
    private var silenceLabel = NSTextField(labelWithString: "")
    private var retentionLabel = NSTextField(labelWithString: "")
    private var memoryLabel = NSTextField(labelWithString: "")
    private var externalField = NSTextField()

    init(settings: Settings, session: DictationSession) {
        self.settings = settings
        self.session = session
        super.init()
    }

    func show() {
        if window == nil { buildWindow() }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await refreshPermissions() }
        refreshValues()
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LocalFlow Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSScrollView()

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false

        let scroll = window.contentView as! NSScrollView
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        section("Dictation", into: content) { stack in
            stack.addArrangedSubview(popupRow("Speech engine", options: ASREngineKind.allCases.map(\.displayName), selected: ASREngineKind.allCases.firstIndex(of: settings.asrEngine) ?? 0) { [weak self] index in
                self?.settings.asrEngine = ASREngineKind.allCases[index]
            })
            stack.addArrangedSubview(popupRow("Cleanup", options: CleanupMode.allCases.map(\.displayName), selected: CleanupMode.allCases.firstIndex(of: settings.cleanupMode) ?? 0) { [weak self] index in
                self?.settings.cleanupMode = CleanupMode.allCases[index]
            })
            stack.addArrangedSubview(popupRow("Trigger key", options: TriggerKey.allCases.map(\.displayName), selected: TriggerKey.allCases.firstIndex(of: settings.triggerKey) ?? 0) { [weak self] index in
                self?.settings.triggerKey = TriggerKey.allCases[index]
            })
            stack.addArrangedSubview(switchRow("Show Flow Bar", value: settings.showFlowBar) { [weak self] on in self?.settings.showFlowBar = on })
            stack.addArrangedSubview(switchRow("Auto-stop on silence (hands-free)", value: settings.autoStopOnSilence) { [weak self] on in self?.settings.autoStopOnSilence = on })
            stack.addArrangedSubview(switchRow("Play sounds", value: settings.soundsEnabled) { [weak self] on in self?.settings.soundsEnabled = on })
            stack.addArrangedSubview(switchRow("Whisper mode (visual only)", value: settings.whisperMode) { [weak self] on in self?.settings.whisperMode = on })

            let locales = ["en-US", "en-IN", "hi-IN"]
            let localeLabels = ["English (US)", "English (India)", "Hindi (India)"]
            let selectedLocale = locales.firstIndex(of: settings.asrLocale) ?? 0
            stack.addArrangedSubview(popupRow("Recognition language", options: localeLabels, selected: selectedLocale) { [weak self] index in
                self?.settings.asrLocale = locales[index]
            })
            let localeNote = NSTextField(wrappingLabelWithString: "Apple Speech only — Parakeet is English/European and ignores this. On-device recognition is required; locales without it are rejected.")
            localeNote.textColor = .secondaryLabelColor
            localeNote.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(localeNote)
        }

        section("Meetings", into: content) { stack in
            stack.addArrangedSubview(switchRow("Suggest transcription when a call is detected", value: settings.suggestMeetings) { [weak self] on in self?.settings.suggestMeetings = on })
            let note = NSTextField(wrappingLabelWithString: "Meeting transcription captures your microphone (Me) and system audio (Them), diarizes remote speakers, and saves a Markdown transcript to ~/Documents/LocalFlow Meetings. Requires Screen & System Audio Recording permission. Let participants know you are transcribing; headphones give the cleanest split.")
            note.textColor = .secondaryLabelColor
            note.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(note)
        }

        section("Recording", into: content) { stack in
            maxRecordLabel.stringValue = "Max recording: \(settings.maxRecordingSeconds / 60) min"
            let stepper = NSStepper()
            stepper.minValue = 60; stepper.maxValue = 14400; stepper.increment = 60
            stepper.doubleValue = Double(settings.maxRecordingSeconds)
            stepper.target = self; stepper.action = #selector(maxRecordingChanged(_:))
            stack.addArrangedSubview(row("Max recording", control: stepper, detail: maxRecordLabel))

            silenceLabel.stringValue = String(format: "Silence timeout: %.1fs", settings.silenceTimeoutSeconds)
            let slider = NSSlider(value: settings.silenceTimeoutSeconds, minValue: 0.5, maxValue: 3.0, target: self, action: #selector(silenceChanged(_:)))
            slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
            stack.addArrangedSubview(row("Silence timeout", control: slider, detail: silenceLabel))

            retentionLabel.stringValue = "History retention: \(settings.historyRetentionDays) days"
            let retStepper = NSStepper()
            retStepper.minValue = 1; retStepper.maxValue = 90; retStepper.increment = 1
            retStepper.integerValue = settings.historyRetentionDays
            retStepper.target = self; retStepper.action = #selector(retentionChanged(_:))
            stack.addArrangedSubview(row("History retention", control: retStepper, detail: retentionLabel))
        }

        section("Cleanup model", into: content) { stack in
            externalField.placeholderString = "External command (stdin prompt, stdout text)"
            externalField.stringValue = settings.externalLLMCommand
            externalField.target = self; externalField.action = #selector(externalChanged(_:))
            externalField.widthAnchor.constraint(equalToConstant: 420).isActive = true
            stack.addArrangedSubview(externalField)
            let note = NSTextField(wrappingLabelWithString: "Rules-only cleanup uses no LLM. Apple Intelligence runs in a system process; external commands are your responsibility.")
            note.textColor = .secondaryLabelColor
            note.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(note)
        }

        section("Permissions", into: content) { stack in
            micLabel.stringValue = "—"; speechLabel.stringValue = "—"; axLabel.stringValue = "—"
            stack.addArrangedSubview(permissionRow("Microphone", label: micLabel, tag: 0))
            stack.addArrangedSubview(permissionRow("Speech recognition", label: speechLabel, tag: 1))
            stack.addArrangedSubview(permissionRow("Accessibility", label: axLabel, tag: 2))
        }

        section("Models", into: content) { stack in
            let text = NSTextView()
            text.isEditable = false
            text.isSelectable = true
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.string = ModelCatalog.models.map { "\($0.name) [\($0.kind)] \($0.license) — \($0.notes)" }.joined(separator: "\n")
            text.heightAnchor.constraint(equalToConstant: 120).isActive = true
            stack.addArrangedSubview(text)
        }

        section("Memory", into: content) { stack in
            memoryLabel.stringValue = session.memoryMB.map { String(format: "Last measured footprint: %.1f MB", $0) } ?? "Run a dictation to measure memory."
            stack.addArrangedSubview(memoryLabel)
            let note = NSTextField(wrappingLabelWithString: "Target: under 1 GB for the app process. System-run models are reported separately by macOS.")
            note.textColor = .secondaryLabelColor
            note.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(note)
        }

        self.window = window
    }

    private func section(_ title: String, into stack: NSStackView, _ body: (NSStackView) -> Void) {
        let header = NSTextField(labelWithString: title)
        header.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(header)
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 8
        group.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        body(group)
        stack.addArrangedSubview(group)
    }

    private func row(_ title: String, control: NSView, detail: NSTextField? = nil) -> NSView {
        let h = NSStackView()
        h.orientation = .horizontal
        h.spacing = 10
        h.alignment = .centerY
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true
        h.addArrangedSubview(label)
        h.addArrangedSubview(control)
        if let detail { h.addArrangedSubview(detail) }
        return h
    }

    private func popupRow(_ title: String, options: [String], selected: Int, onSelect: @escaping (Int) -> Void) -> NSView {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: options)
        popup.selectItem(at: selected)
        popup.target = self
        popup.action = #selector(popupChanged(_:))
        popup.tag = title.hashValue
        popupHandlers[popup] = onSelect
        return row(title, control: popup)
    }

    private var popupHandlers: [NSPopUpButton: (Int) -> Void] = [:]

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        popupHandlers[sender]?(sender.indexOfSelectedItem)
    }

    private func switchRow(_ title: String, value: Bool, onChange: @escaping (Bool) -> Void) -> NSView {
        let toggle = NSSwitch()
        toggle.state = value ? .on : .off
        toggle.target = self
        toggle.action = #selector(switchChanged(_:))
        switchHandlers[toggle] = onChange
        return row(title, control: toggle)
    }

    private var switchHandlers: [NSSwitch: (Bool) -> Void] = [:]

    @objc private func switchChanged(_ sender: NSSwitch) {
        switchHandlers[sender]?(sender.state == .on)
    }

    private func permissionRow(_ title: String, label: NSTextField, tag: Int) -> NSView {
        let h = NSStackView()
        h.orientation = .horizontal
        h.spacing = 10
        h.alignment = .centerY
        let name = NSTextField(labelWithString: title)
        name.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let button = NSButton(title: "Grant", target: self, action: #selector(permissionTapped(_:)))
        button.tag = tag
        h.addArrangedSubview(name)
        h.addArrangedSubview(label)
        h.addArrangedSubview(button)
        permissionButtons[tag] = (label, button)
        return h
    }

    private var permissionButtons: [Int: (NSTextField, NSButton)] = [:]

    @objc private func permissionTapped(_ sender: NSButton) {
        Task {
            switch sender.tag {
            case 0: _ = await Permissions.requestMicrophone()
            case 1: _ = await Permissions.requestSpeechRecognition()
            case 2: _ = Permissions.requestAccessibility(prompt: true)
            default: break
            }
            await refreshPermissions()
        }
    }

    private func refreshPermissions() async {
        let status = await Permissions.status()
        permissionButtons[0]?.0.stringValue = status.microphone ? "Granted" : "Not granted"
        permissionButtons[1]?.0.stringValue = status.speechRecognition ? "Granted" : "Not granted"
        permissionButtons[2]?.0.stringValue = status.accessibility ? "Granted" : "Not granted"
        for (index, pair) in permissionButtons {
            let granted = index == 0 ? status.microphone : index == 1 ? status.speechRecognition : status.accessibility
            pair.1.isEnabled = !granted
        }
    }

    private func refreshValues() {
        maxRecordLabel.stringValue = "Max recording: \(settings.maxRecordingSeconds / 60) min"
        silenceLabel.stringValue = String(format: "Silence timeout: %.1fs", settings.silenceTimeoutSeconds)
        retentionLabel.stringValue = "History retention: \(settings.historyRetentionDays) days"
        memoryLabel.stringValue = session.memoryMB.map { String(format: "Last measured footprint: %.1f MB", $0) } ?? "Run a dictation to measure memory."
        externalField.stringValue = settings.externalLLMCommand
    }

    @objc private func maxRecordingChanged(_ sender: NSStepper) {
        settings.maxRecordingSeconds = Int(sender.doubleValue)
        maxRecordLabel.stringValue = "Max recording: \(settings.maxRecordingSeconds / 60) min"
    }

    @objc private func silenceChanged(_ sender: NSSlider) {
        settings.silenceTimeoutSeconds = sender.doubleValue
        silenceLabel.stringValue = String(format: "Silence timeout: %.1fs", sender.doubleValue)
    }

    @objc private func retentionChanged(_ sender: NSStepper) {
        settings.historyRetentionDays = sender.integerValue
        retentionLabel.stringValue = "History retention: \(settings.historyRetentionDays) days"
    }

    @objc private func externalChanged(_ sender: NSTextField) {
        settings.externalLLMCommand = sender.stringValue
    }
}
