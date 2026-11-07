import AppKit
import LocalFlowCore

/// Hub window: sidebar + panes for Home stats/history, Dictionary, Snippets,
/// writing styles, Setup/permissions, and a shortcut to Settings.
@MainActor
final class HubWindowController: NSObject {
    enum Pane: String, CaseIterable {
        case home = "Home"
        case meetings = "Meetings"
        case dictionary = "Dictionary"
        case snippets = "Snippets"
        case style = "Style"
        case setup = "Setup"
        case settings = "Settings"
    }

    private let store: HistoryStore?
    private let session: DictationSession
    private let meeting: MeetingSession?
    private let settings: Settings
    private weak var appDelegate: AppDelegate?

    private var window: NSWindow?
    private var paneViews: [Pane: NSView] = [:]
    private var sidebarButtons: [Pane: NSButton] = [:]
    private var selectedPane: Pane = .home

    private var homeStatsLabel = NSTextField(labelWithString: "")
    private var homeEntriesStack = NSStackView()
    private var dictRowsStack = NSStackView()
    private var dictTermField = NSTextField()
    private var dictReplacementField = NSTextField()
    private var snippetRowsStack = NSStackView()
    private var snippetTriggerField = NSTextField()
    private var snippetExpansionView = NSTextView()
    private var setupPermissionButtons: [Int: (NSTextField, NSButton)] = [:]
    private var permissionTimer: Timer?
    private var meetingRowsStack = NSStackView()
    private var meetingFiles: [MeetingFileInfo] = []
    private var meetingToggleButton = NSButton(title: "", target: nil, action: nil)
    private var meetingStatusLabel = NSTextField(labelWithString: "")
    private var dictItems: [(term: String, replacement: String)] = []
    private var snippetItems: [(trigger: String, expansion: String)] = []
    private var historyEntries: [HistoryEntry] = []

    init(store: HistoryStore?, session: DictationSession, meeting: MeetingSession? = nil, settings: Settings, appDelegate: AppDelegate) {
        self.store = store
        self.session = session
        self.meeting = meeting
        self.settings = settings
        self.appDelegate = appDelegate
        super.init()
    }

    func show(pane: Pane = .home) {
        if window == nil { buildWindow() }
        select(pane)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await refreshAll() }
    }

    // MARK: - Window construction

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LocalFlow"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 480)

        let root = NSStackView()
        root.orientation = .horizontal
        root.spacing = 0
        root.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        root.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = buildSidebar()
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(sidebar)
        root.addArrangedSubview(content)

        window.contentView = NSView()
        window.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])

        for pane in Pane.allCases {
            let view = buildPane(pane)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isHidden = (pane != selectedPane)
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                view.topAnchor.constraint(equalTo: content.topAnchor),
                view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
            paneViews[pane] = view
        }

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window?.isVisible == true else { return }
                await self.refreshPermissions()
            }
        }

        self.window = window
    }

    private func buildSidebar() -> NSView {
        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.spacing = 2
        sidebar.edgeInsets = NSEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.widthAnchor.constraint(equalToConstant: 168).isActive = true

        let title = NSTextField(labelWithString: "LocalFlow")
        title.font = .boldSystemFont(ofSize: 15)
        title.alignment = .left
        sidebar.addArrangedSubview(title)

        for pane in Pane.allCases {
            let button = NSButton(title: pane.rawValue, target: self, action: #selector(paneTapped(_:)))
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 13)
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.tag = Pane.allCases.firstIndex(of: pane) ?? 0
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            button.setContentHuggingPriority(.required, for: .vertical)
            sidebar.addArrangedSubview(button)
            sidebarButtons[pane] = button
        }
        sidebar.addArrangedSubview(NSView())
        return sidebar
    }

    @objc private func paneTapped(_ sender: NSButton) {
        guard let pane = Pane.allCases[safe: sender.tag] else { return }
        select(pane)
    }

    private func select(_ pane: Pane) {
        selectedPane = pane
        for (key, button) in sidebarButtons {
            let selected = (key == pane)
            button.layer?.backgroundColor = selected
                ? NSColor(srgbRed: 0.30, green: 0.34, blue: 0.46, alpha: 0.55).cgColor
                : NSColor.clear.cgColor
            button.contentTintColor = selected ? .white : .labelColor
            button.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        }
        paneViews.forEach { $0.value.isHidden = ($0.key != pane) }
        if pane == .setup {
            Task { await refreshPermissions() }
        }
        if pane == .home || pane == .dictionary || pane == .snippets {
            Task { await refreshData() }
        }
        if pane == .meetings {
            Task { await refreshMeetings() }
        }
    }

    // MARK: - Pane builders

    private func buildPane(_ pane: Pane) -> NSView {
        switch pane {
        case .home: return buildHomePane()
        case .meetings: return buildMeetingsPane()
        case .dictionary: return buildDictionaryPane()
        case .snippets: return buildSnippetsPane()
        case .style: return buildStylePane()
        case .setup: return buildSetupPane()
        case .settings: return buildSettingsPane()
        }
    }

    private func scrollableStack(_ stack: NSStackView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    private func paneHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 15)
        return label
    }

    private func noteLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 11)
        return label
    }

    // MARK: - Home

    private func buildHomePane() -> NSView {
        homeStatsLabel.font = .systemFont(ofSize: 12)
        homeStatsLabel.textColor = .secondaryLabelColor

        let clearButton = NSButton(title: "Clear history", target: self, action: #selector(clearHistoryTapped))
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 10
        header.alignment = .centerY
        header.addArrangedSubview(paneHeader("History"))
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(clearButton)

        homeEntriesStack = NSStackView()
        homeEntriesStack.orientation = .vertical
        homeEntriesStack.alignment = .leading
        homeEntriesStack.spacing = 6

        let scroll = scrollableStack(homeEntriesStack)
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(header)
        root.addArrangedSubview(homeStatsLabel)
        root.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return root
    }

    @objc private func clearHistoryTapped() {
        Task {
            try? await store?.deleteAllHistory()
            historyEntries = []
            rebuildHome()
        }
    }

    private func rebuildHome() {
        homeEntriesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let entries = historyEntries
        if entries.isEmpty {
            homeEntriesStack.addArrangedSubview(NSTextField(labelWithString: "No dictations yet."))
            homeStatsLabel.stringValue = ""
            return
        }
        let words = entries.reduce(0) { $0 + $1.cleanText.split { $0 == " " || $0 == "\n" }.count }
        let minutes = entries.reduce(0.0) { $0 + $1.durationMilliseconds } / 60_000
        let wpm = minutes > 0 ? Double(words) / minutes : 0
        homeStatsLabel.stringValue = String(
            format: "%d dictations · %d words · %.1f WPM average",
            entries.count, words, wpm
        )
        for (index, entry) in entries.prefix(100).enumerated() {
            homeEntriesStack.addArrangedSubview(historyRow(entry, copyIndex: index))
        }
    }

    private func historyRow(_ entry: HistoryEntry, copyIndex: Int) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.08).cgColor
        box.layer?.cornerRadius = 8

        let meta = NSTextField(labelWithString: "\(entry.createdAt.formatted(date: .abbreviated, time: .shortened)) — \(entry.appName.isEmpty ? entry.bundleID : entry.appName) — \(entry.engine)")
        meta.font = .boldSystemFont(ofSize: 10)
        meta.textColor = .secondaryLabelColor
        let clean = NSTextField(wrappingLabelWithString: entry.cleanText)
        clean.font = .systemFont(ofSize: 12)
        clean.maximumNumberOfLines = 3
        clean.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.addArrangedSubview(meta)
        textStack.addArrangedSubview(clean)

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyHistoryTapped(_:)))
        copyButton.bezelStyle = .rounded
        copyButton.tag = copyIndex
        copyButton.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .top
        row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(copyButton)
        textStack.widthAnchor.constraint(lessThanOrEqualToConstant: 480).isActive = true

        box.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            row.topAnchor.constraint(equalTo: box.topAnchor),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    @objc private func copyHistoryTapped(_ sender: NSButton) {
        guard historyEntries.indices.contains(sender.tag) else { return }
        let text = historyEntries[sender.tag].cleanText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Meetings

    private func buildMeetingsPane() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.alignment = .leading

        root.addArrangedSubview(paneHeader("Meetings"))
        root.addArrangedSubview(noteLabel("Transcripts are saved as Markdown in ~/Documents/LocalFlow Meetings. Let participants know you are transcribing — and use headphones for the cleanest Me/Them split."))

        meetingStatusLabel.font = .systemFont(ofSize: 12)
        meetingStatusLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(meetingStatusLabel)

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 10
        controls.alignment = .centerY

        meetingToggleButton.bezelStyle = .rounded
        meetingToggleButton.target = self
        meetingToggleButton.action = #selector(meetingToggleTapped)
        controls.addArrangedSubview(meetingToggleButton)

        let folderButton = NSButton(title: "Open Folder", target: self, action: #selector(openMeetingsFolderTapped))
        folderButton.bezelStyle = .rounded
        controls.addArrangedSubview(folderButton)
        root.addArrangedSubview(controls)

        meetingRowsStack.orientation = .vertical
        meetingRowsStack.alignment = .leading
        meetingRowsStack.spacing = 6
        meetingRowsStack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = scrollableStack(meetingRowsStack)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return root
    }

    private func refreshMeetings() async {
        meetingFiles = MeetingTranscriptWriter.listTranscripts()
        updateMeetingStatus()
        rebuildMeetingRows()
    }

    private func updateMeetingStatus() {
        guard let meeting else {
            meetingStatusLabel.stringValue = ""
            meetingToggleButton.isHidden = true
            return
        }
        meetingToggleButton.isHidden = false
        switch meeting.state {
        case .idle:
            meetingToggleButton.title = "Start Meeting Transcription"
            meetingStatusLabel.stringValue = meetingFiles.isEmpty
                ? "No transcripts yet."
                : "\(meetingFiles.count) transcript\(meetingFiles.count == 1 ? "" : "s") saved."
        case .starting:
            meetingToggleButton.title = "Cancel Start"
            meetingStatusLabel.stringValue = "Preparing…"
        case .recording(let startedAt):
            let seconds = Int(Date().timeIntervalSince(startedAt))
            meetingToggleButton.title = String(format: "Stop Meeting (%d:%02d)", seconds / 60, seconds % 60)
            meetingStatusLabel.stringValue = "Recording — \(meeting.lineCount) lines"
        case .finishing:
            meetingToggleButton.title = "Finishing…"
            meetingToggleButton.isEnabled = false
            meetingStatusLabel.stringValue = "Finishing transcript…"
        case .error(let message):
            meetingToggleButton.title = "Start Meeting Transcription"
            meetingStatusLabel.stringValue = "Error: \(message)"
        }
        if case .finishing = meeting.state {} else {
            meetingToggleButton.isEnabled = true
        }
    }

    private func rebuildMeetingRows() {
        meetingRowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if meetingFiles.isEmpty {
            meetingRowsStack.addArrangedSubview(noteLabel("No meeting transcripts yet."))
            return
        }
        for (index, file) in meetingFiles.enumerated() {
            meetingRowsStack.addArrangedSubview(meetingRow(file, tag: index))
        }
    }

    private func meetingRow(_ file: MeetingFileInfo, tag: Int) -> NSView {
        let nameLabel = NSTextField(labelWithString: file.name)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle

        var detail = file.modified.formatted(date: .abbreviated, time: .shortened)
        if let duration = file.duration {
            detail += " · \(Self.durationString(duration))"
        }
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor

        let text = NSStackView()
        text.orientation = .vertical
        text.spacing = 1
        text.alignment = .leading
        text.addArrangedSubview(nameLabel)
        text.addArrangedSubview(detailLabel)

        let openButton = NSButton(title: "Open", target: self, action: #selector(meetingOpenTapped(_:)))
        openButton.bezelStyle = .rounded
        openButton.tag = tag
        let revealButton = NSButton(title: "Reveal", target: self, action: #selector(meetingRevealTapped(_:)))
        revealButton.bezelStyle = .rounded
        revealButton.tag = tag
        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(meetingDeleteTapped(_:)))
        deleteButton.bezelStyle = .rounded
        deleteButton.tag = tag
        deleteButton.contentTintColor = .systemRed

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(openButton)
        row.addArrangedSubview(revealButton)
        row.addArrangedSubview(deleteButton)
        text.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        return row
    }

    private static func durationString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    @objc private func meetingToggleTapped() {
        guard let meeting else { return }
        Task {
            if meeting.isRecording || meeting.state == .starting {
                await meeting.stop()
            } else {
                await meeting.start()
            }
            await refreshMeetings()
        }
    }

    @objc private func openMeetingsFolderTapped() {
        let dir = MeetingTranscriptWriter.meetingsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func meetingOpenTapped(_ sender: NSButton) {
        guard let file = meetingFiles[safe: sender.tag] else { return }
        NSWorkspace.shared.open(file.url)
    }

    @objc private func meetingRevealTapped(_ sender: NSButton) {
        guard let file = meetingFiles[safe: sender.tag] else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    @objc private func meetingDeleteTapped(_ sender: NSButton) {
        guard let file = meetingFiles[safe: sender.tag] else { return }
        let alert = NSAlert()
        alert.messageText = "Delete meeting transcript?"
        alert.informativeText = file.name
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(at: file.url)
        Task { await refreshMeetings() }
    }

    // MARK: - Dictionary

    private func buildDictionaryPane() -> NSView {
        let termField = NSTextField()
        termField.placeholderString = "Term (e.g. Kronos)"
        termField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        dictTermField = termField

        let replacementField = NSTextField()
        replacementField.placeholderString = "Replacement (optional — biases spelling)"
        replacementField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        dictReplacementField = replacementField

        let addButton = NSButton(title: "Add", target: self, action: #selector(dictAddTapped))
        addButton.bezelStyle = .rounded

        let addRow = NSStackView()
        addRow.orientation = .horizontal
        addRow.spacing = 8
        addRow.alignment = .centerY
        addRow.addArrangedSubview(termField)
        addRow.addArrangedSubview(replacementField)
        addRow.addArrangedSubview(addButton)

        dictRowsStack = NSStackView()
        dictRowsStack.orientation = .vertical
        dictRowsStack.alignment = .leading
        dictRowsStack.spacing = 4

        let scroll = scrollableStack(dictRowsStack)
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(paneHeader("Dictionary"))
        root.addArrangedSubview(noteLabel("Terms bias speech recognition. A replacement rewrites matches; leave it empty to only fix spelling."))
        root.addArrangedSubview(addRow)
        root.addArrangedSubview(scroll)
        return root
    }

    @objc private func dictAddTapped() {
        let term = dictTermField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        let replacement = dictReplacementField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = replacement.isEmpty ? term : replacement
        Task {
            try? await store?.upsertDictionary(VocabularyItem(term: term, replacement: value))
            await session.reloadVocabulary()
            dictTermField.stringValue = ""
            dictReplacementField.stringValue = ""
            await refreshDictionary()
        }
    }

    private func refreshDictionary() async {
        dictItems = ((try? await store?.loadDictionary()) ?? [:])
            .map { (term: $0.key, replacement: $0.value) }
            .sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
        rebuildDictionary()
    }

    private func rebuildDictionary() {
        dictRowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if dictItems.isEmpty {
            dictRowsStack.addArrangedSubview(NSTextField(labelWithString: "No dictionary terms yet."))
            return
        }
        for (index, item) in dictItems.enumerated() {
            let termLabel = NSTextField(labelWithString: item.term)
            termLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            termLabel.widthAnchor.constraint(equalToConstant: 180).isActive = true

            let replacementText = item.replacement == item.term ? "(bias only)" : item.replacement
            let replacementLabel = NSTextField(labelWithString: replacementText)
            replacementLabel.textColor = .secondaryLabelColor
            replacementLabel.font = .systemFont(ofSize: 12)

            let deleteButton = NSButton(title: "Delete", target: self, action: #selector(dictDeleteTapped(_:)))
            deleteButton.bezelStyle = .rounded
            deleteButton.tag = index
            deleteButton.setContentHuggingPriority(.required, for: .horizontal)

            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 10
            row.alignment = .centerY
            row.addArrangedSubview(termLabel)
            row.addArrangedSubview(replacementLabel)
            row.addArrangedSubview(NSView())
            row.addArrangedSubview(deleteButton)
            row.widthAnchor.constraint(equalTo: dictRowsStack.widthAnchor).isActive = true
            dictRowsStack.addArrangedSubview(row)
        }
    }

    @objc private func dictDeleteTapped(_ sender: NSButton) {
        guard dictItems.indices.contains(sender.tag) else { return }
        let term = dictItems[sender.tag].term
        Task {
            try? await store?.deleteDictionary(term: term)
            await session.reloadVocabulary()
            await refreshDictionary()
        }
    }

    // MARK: - Snippets

    private func buildSnippetsPane() -> NSView {
        let triggerField = NSTextField()
        triggerField.placeholderString = "Trigger phrase"
        triggerField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        snippetTriggerField = triggerField

        let addButton = NSButton(title: "Add", target: self, action: #selector(snippetAddTapped))
        addButton.bezelStyle = .rounded

        snippetExpansionView.isEditable = true
        snippetExpansionView.isSelectable = true
        snippetExpansionView.font = .systemFont(ofSize: 12)
        snippetExpansionView.string = ""
        snippetExpansionView.minSize = NSSize(width: 0, height: 56)
        snippetExpansionView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 120)
        snippetExpansionView.isVerticallyResizable = true
        snippetExpansionView.isHorizontallyResizable = false
        snippetExpansionView.textContainerInset = NSSize(width: 4, height: 4)
        snippetExpansionView.textContainer?.widthTracksTextView = true
        snippetExpansionView.textContainer?.containerSize = NSSize(width: 440, height: CGFloat.greatestFiniteMagnitude)

        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.spacing = 8
        topRow.alignment = .centerY
        topRow.addArrangedSubview(triggerField)
        topRow.addArrangedSubview(addButton)

        snippetRowsStack = NSStackView()
        snippetRowsStack.orientation = .vertical
        snippetRowsStack.alignment = .leading
        snippetRowsStack.spacing = 4

        let scroll = scrollableStack(snippetRowsStack)
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(paneHeader("Snippets"))
        root.addArrangedSubview(noteLabel("Say the trigger phrase verbatim to insert the expansion."))
        root.addArrangedSubview(topRow)
        let expansionScroll = NSScrollView()
        expansionScroll.hasVerticalScroller = true
        expansionScroll.borderType = .lineBorder
        expansionScroll.documentView = snippetExpansionView
        expansionScroll.heightAnchor.constraint(equalToConstant: 64).isActive = true
        expansionScroll.widthAnchor.constraint(equalToConstant: 460).isActive = true
        root.addArrangedSubview(expansionScroll)
        root.addArrangedSubview(scroll)
        return root
    }

    @objc private func snippetAddTapped() {
        let trigger = snippetTriggerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let expansion = snippetExpansionView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty, !expansion.isEmpty else { return }
        Task {
            try? await store?.upsertSnippet(VocabularyItem(term: trigger, replacement: expansion))
            await session.reloadVocabulary()
            snippetTriggerField.stringValue = ""
            snippetExpansionView.string = ""
            await refreshSnippets()
        }
    }

    private func refreshSnippets() async {
        snippetItems = ((try? await store?.loadSnippets()) ?? [:])
            .map { (trigger: $0.key, expansion: $0.value) }
            .sorted { $0.trigger.localizedCaseInsensitiveCompare($1.trigger) == .orderedAscending }
        rebuildSnippets()
    }

    private func rebuildSnippets() {
        snippetRowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if snippetItems.isEmpty {
            snippetRowsStack.addArrangedSubview(NSTextField(labelWithString: "No snippets yet."))
            return
        }
        for (index, item) in snippetItems.enumerated() {
            let triggerLabel = NSTextField(labelWithString: item.trigger)
            triggerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            triggerLabel.widthAnchor.constraint(equalToConstant: 200).isActive = true

            let preview = item.expansion.replacingOccurrences(of: "\n", with: " ⏎ ")
            let expansionLabel = NSTextField(labelWithString: preview)
            expansionLabel.textColor = .secondaryLabelColor
            expansionLabel.font = .systemFont(ofSize: 12)
            expansionLabel.lineBreakMode = .byTruncatingTail

            let deleteButton = NSButton(title: "Delete", target: self, action: #selector(snippetDeleteTapped(_:)))
            deleteButton.bezelStyle = .rounded
            deleteButton.tag = index
            deleteButton.setContentHuggingPriority(.required, for: .horizontal)

            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 10
            row.alignment = .centerY
            row.addArrangedSubview(triggerLabel)
            row.addArrangedSubview(expansionLabel)
            row.addArrangedSubview(NSView())
            row.addArrangedSubview(deleteButton)
            row.widthAnchor.constraint(equalTo: snippetRowsStack.widthAnchor).isActive = true
            snippetRowsStack.addArrangedSubview(row)
        }
    }

    @objc private func snippetDeleteTapped(_ sender: NSButton) {
        guard snippetItems.indices.contains(sender.tag) else { return }
        let trigger = snippetItems[sender.tag].trigger
        Task {
            try? await store?.deleteSnippet(trigger: trigger)
            await session.reloadVocabulary()
            await refreshSnippets()
        }
    }

    // MARK: - Style

    private func buildStylePane() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.alignment = .leading

        root.addArrangedSubview(paneHeader("Writing styles"))
        root.addArrangedSubview(noteLabel("Cleanup tone is chosen by the frontmost app. Literal-mode apps (Terminal, IDEs) always bypass styling."))

        root.addArrangedSubview(styleRow("Messaging apps", get: { $0.messagingStyle }, set: { $0.messagingStyle = $1 }, example: "Hey, sounds good"))
        root.addArrangedSubview(styleRow("Email apps", get: { $0.emailStyle }, set: { $0.emailStyle = $1 }, example: "Hello there, my friend."))
        root.addArrangedSubview(styleRow("Other apps", get: { $0.otherStyle }, set: { $0.otherStyle = $1 }, example: "Hello there, my friend."))
        return root
    }

    private func styleRow(_ title: String, get: @escaping (Settings) -> WritingStyle, set: @escaping (Settings, WritingStyle) -> Void, example: String) -> NSView {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: WritingStyle.allCases.map(\.displayName))
        let current = get(settings)
        popup.selectItem(at: WritingStyle.allCases.firstIndex(of: current) ?? 0)
        popupHandlers[popup] = { [weak self] index in
            guard let self else { return }
            set(self.settings, WritingStyle.allCases[index])
        }
        popup.target = self
        popup.action = #selector(stylePopupChanged(_:))

        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let exampleLabel = NSTextField(labelWithString: "e.g. \"\(example)\"")
        exampleLabel.textColor = .secondaryLabelColor
        exampleLabel.font = .systemFont(ofSize: 11)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.addArrangedSubview(label)
        row.addArrangedSubview(popup)
        row.addArrangedSubview(exampleLabel)
        return row
    }

    private var popupHandlers: [NSPopUpButton: (Int) -> Void] = [:]

    @objc private func stylePopupChanged(_ sender: NSPopUpButton) {
        popupHandlers[sender]?(sender.indexOfSelectedItem)
    }

    // MARK: - Setup

    private func buildSetupPane() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.alignment = .leading

        root.addArrangedSubview(paneHeader("Setup"))

        let micLabel = NSTextField(labelWithString: "—")
        let speechLabel = NSTextField(labelWithString: "—")
        let axLabel = NSTextField(labelWithString: "—")
        setupPermissionButtons[0] = (micLabel, NSButton(title: "Grant", target: self, action: #selector(permissionTapped(_:))))
        setupPermissionButtons[1] = (speechLabel, NSButton(title: "Grant", target: self, action: #selector(permissionTapped(_:))))
        setupPermissionButtons[2] = (axLabel, NSButton(title: "Grant", target: self, action: #selector(permissionTapped(_:))))
        for index in 0..<3 {
            let title = ["Microphone", "Speech Recognition", "Accessibility"][index]
            let pair = setupPermissionButtons[index]!
            pair.1.tag = index
            root.addArrangedSubview(permissionRow(title, label: pair.0, button: pair.1))
        }

        let openAX = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibilitySettings))
        openAX.bezelStyle = .rounded
        root.addArrangedSubview(openAX)

        root.addArrangedSubview(noteLabel("Set System Settings › Keyboard › 'Press fn key to' = Do Nothing (only needed for the Fn trigger)."))
        root.addArrangedSubview(noteLabel("Quit Wispr Flow while using LocalFlow — both apps use the Fn key."))

        let cheatTitle = NSTextField(labelWithString: "Hotkeys")
        cheatTitle.font = .boldSystemFont(ofSize: 12)
        root.addArrangedSubview(cheatTitle)
        let key = settings.triggerKey.shortName
        for line in [
            "Hold \(key) — dictate; release to transcribe and insert",
            "Double-tap \(key) — hands-free; tap again or press the Flow Bar stop button to finish",
            "Esc — cancel dictation",
            "\(key) + Control — Command Mode (edit the selected text with Apple Intelligence)",
            "Ctrl+Cmd+V — paste last transcript",
        ] {
            let label = NSTextField(labelWithString: "• \(line)")
            label.font = .systemFont(ofSize: 12)
            root.addArrangedSubview(label)
        }
        return root
    }

    private func permissionRow(_ title: String, label: NSTextField, button: NSButton) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.addArrangedSubview(name)
        row.addArrangedSubview(label)
        row.addArrangedSubview(button)
        return row
    }

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

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshPermissions() async {
        let status = await Permissions.status()
        setupPermissionButtons[0]?.0.stringValue = status.microphone ? "Granted" : "Not granted"
        setupPermissionButtons[1]?.0.stringValue = status.speechRecognition ? "Granted" : "Not granted"
        setupPermissionButtons[2]?.0.stringValue = status.accessibility ? "Granted" : "Not granted"
        for (index, pair) in setupPermissionButtons {
            let granted = index == 0 ? status.microphone : index == 1 ? status.speechRecognition : status.accessibility
            pair.1.isEnabled = !granted
        }
    }

    // MARK: - Settings pane

    private func buildSettingsPane() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.alignment = .leading

        root.addArrangedSubview(paneHeader("Settings"))
        root.addArrangedSubview(noteLabel("Engine, cleanup mode, trigger key, recording limits, models, and memory live in the Settings window."))
        let openButton = NSButton(title: "Open Settings…", target: self, action: #selector(openSettingsTapped))
        openButton.bezelStyle = .rounded
        root.addArrangedSubview(openButton)
        return root
    }

    @objc private func openSettingsTapped() {
        appDelegate?.showSettings()
    }

    // MARK: - Data refresh

    private func refreshAll() async {
        await refreshData()
        await refreshPermissions()
    }

    private func refreshData() async {
        if let store {
            historyEntries = (try? await store.recentHistory(limit: 500)) ?? []
        } else {
            historyEntries = []
        }
        rebuildHome()
        await refreshDictionary()
        await refreshSnippets()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
