import AppKit

/// App-modal checklist of the folders directly inside the one being added.
/// It returns before the first snapshot starts. Cancel adds nothing.
final class FolderSetupPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private let folders: [String]
    private var shown: [String]
    private var excluded: Set<String>
    private var confirmed = false

    private let window: NSWindow
    private let table = NSTableView()
    private let search = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "No folder matches.")
    private let startButton = NSButton()

    init(folderName: String, source: URL) {
        let listing = FolderSetup.folders(in: source)
        folders = listing.names
        shown = listing.names
        excluded = Set(listing.names.filter { VaultConfig.defaultSkip.contains($0) })
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Set up \(folderName)"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.windowBackground
        window.minSize = NSSize(width: 420, height: 340)
        window.isReleasedWhenClosed = false
        window.level = .modalPanel
        window.delegate = self
        build(unreadable: listing.unreadable)
    }

    /// The skip list to store, or nil when the user cancels. Cancel does not add the folder.
    func run() -> [String]? {
        apply(query: "")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        table.sizeLastColumnToFit()
        NSApp.runModal(for: window)
        window.orderOut(nil)
        guard confirmed else { return nil }
        return FolderSetup.skipNames(folders: folders, excluded: excluded)
    }

    private func build(unreadable: Bool) {
        guard let content = window.contentView else { return }
        let text = unreadable
            ? "Chronicle could not list the folders here. The usual names will still be left out. The first snapshot starts when you continue."
            : "These are the folders directly inside this one, including names that start with a dot. Check one to leave it out. Chronicle will not read it, or another folder with the same name. The usual names stay left out unless you clear that folder."
        let message = NSTextField(wrappingLabelWithString: text)
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 5

        search.placeholderString = "Filter"
        search.delegate = self

        count.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.selectionHighlightStyle = .none
        table.rowHeight = 24
        table.backgroundColor = NSColor(srgbRed: 0.10, green: 0.105, blue: 0.12, alpha: 1)
        table.usesAlternatingRowBackgroundColors = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = table
        scroll.borderType = .bezelBorder

        empty.stringValue = folders.isEmpty ? "No folders in here." : "No folder matches."
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
        empty.isHidden = true

        startButton.title = "Start Snapshot"
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(confirm(_:))

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        for view in [message, search, count, scroll, empty, cancel, startButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            message.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            message.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            message.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            search.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: message.leadingAnchor),
            count.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            count.leadingAnchor.constraint(equalTo: search.trailingAnchor, constant: 8),
            count.trailingAnchor.constraint(equalTo: message.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: message.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: message.trailingAnchor),

            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            cancel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            startButton.centerYAnchor.constraint(equalTo: cancel.centerYAnchor),
            startButton.trailingAnchor.constraint(equalTo: message.trailingAnchor),
            cancel.trailingAnchor.constraint(equalTo: startButton.leadingAnchor, constant: -8),
        ])
    }

    private func apply(query: String) {
        shown = FolderSetup.matching(folders, query: query)
        table.reloadData()
        empty.isHidden = !shown.isEmpty
        updateCount()
    }

    private func updateCount() {
        let base: String
        if shown.count == folders.count {
            base = folders.count == 1 ? "1 folder" : "\(folders.count) folders"
        } else {
            base = "\(shown.count) of \(folders.count)"
        }
        if excluded.isEmpty {
            count.stringValue = base
        } else if excluded.count == 1 {
            count.stringValue = base + " · 1 left out"
        } else {
            count.stringValue = base + " · \(excluded.count) left out"
        }
    }

    @objc private func toggle(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard row >= 0, row < shown.count else { return }
        let name = shown[row]
        if excluded.contains(name) {
            excluded.remove(name)
            sender.state = .off
        } else {
            excluded.insert(name)
            sender.state = .on
        }
        updateCount()
    }

    @objc private func confirm(_ sender: Any?) {
        confirmed = true
        NSApp.stopModal()
    }

    @objc private func cancel(_ sender: Any?) {
        confirmed = false
        NSApp.stopModal()
    }

    func controlTextDidChange(_ obj: Notification) {
        apply(query: search.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            confirm(control)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancel(control)
            return true
        }
        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        shown.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("name")
        let button: NSButton
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSButton {
            button = reused
        } else {
            button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
            button.identifier = identifier
            button.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            button.lineBreakMode = .byTruncatingMiddle
        }
        let name = shown[row]
        button.title = name
        button.state = excluded.contains(name) ? .on : .off
        return button
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel(sender)
        return false
    }

    func windowDidResize(_ notification: Notification) {
        table.sizeLastColumnToFit()
    }
}
