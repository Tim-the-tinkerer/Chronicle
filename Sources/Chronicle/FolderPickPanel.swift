import AppKit

/// App-modal list of folders in one version. It returns before the save panel opens.
final class FolderPickPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private let all: [String]
    private var shown: [String]
    private var anchor: String?
    private var picked: String?
    private var suppressSelection = false

    private let window: NSWindow
    private let table = NSTableView()
    private let search = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "No folder matches.")
    private let restoreButton = NSButton()

    init(paths: [String], preferred: String?) {
        all = paths
        shown = paths
        anchor = preferred
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Restore a folder"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.windowBackground
        window.minSize = NSSize(width: 420, height: 320)
        window.isReleasedWhenClosed = false
        window.level = .modalPanel
        window.delegate = self
        build()
    }

    /// Folders whose path contains the query. A blank query keeps the full list.
    static func matching(_ paths: [String], query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return paths }
        return paths.filter { $0.lowercased().contains(needle) }
    }

    func run() -> String? {
        apply(query: "")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        table.sizeLastColumnToFit()
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return picked
    }

    private func build() {
        guard let content = window.contentView else { return }
        let message = NSTextField(wrappingLabelWithString: "These folders are in this version, including ones the file list hides. Next, Chronicle asks where to write the one you pick.")
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 3

        search.placeholderString = "Filter"
        search.delegate = self

        count.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(confirm(_:))
        table.target = self
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.rowHeight = 22
        table.backgroundColor = NSColor(srgbRed: 0.10, green: 0.105, blue: 0.12, alpha: 1)
        table.usesAlternatingRowBackgroundColors = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = table
        scroll.borderType = .bezelBorder

        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
        empty.isHidden = true

        restoreButton.title = "Choose Place…"
        restoreButton.bezelStyle = .rounded
        restoreButton.keyEquivalent = "\r"
        restoreButton.target = self
        restoreButton.action = #selector(confirm(_:))
        restoreButton.isEnabled = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        for view in [message, search, count, scroll, empty, cancel, restoreButton] {
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
            restoreButton.centerYAnchor.constraint(equalTo: cancel.centerYAnchor),
            restoreButton.trailingAnchor.constraint(equalTo: message.trailingAnchor),
            cancel.trailingAnchor.constraint(equalTo: restoreButton.leadingAnchor, constant: -8),
        ])
    }

    private func apply(query: String) {
        shown = Self.matching(all, query: query)
        suppressSelection = true
        table.reloadData()
        suppressSelection = false
        if let anchor, let row = shown.firstIndex(of: anchor) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
        restoreButton.isEnabled = table.selectedRow >= 0
        empty.isHidden = !shown.isEmpty
        if shown.count == all.count {
            count.stringValue = all.count == 1 ? "1 folder" : "\(all.count) folders"
        } else {
            count.stringValue = "\(shown.count) of \(all.count)"
        }
    }

    @objc private func confirm(_ sender: Any?) {
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { return }
        picked = shown[row]
        NSApp.stopModal()
    }

    @objc private func cancel(_ sender: Any?) {
        picked = nil
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

    func tableViewSelectionDidChange(_ notification: Notification) {
        if suppressSelection { return }
        if table.selectedRow >= 0, table.selectedRow < shown.count {
            anchor = shown[table.selectedRow]
        } else {
            anchor = nil
        }
        restoreButton.isEnabled = table.selectedRow >= 0
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        shown.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("path")
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.lineBreakMode = .byTruncatingMiddle
        }
        field.stringValue = shown[row]
        return field
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel(sender)
        return false
    }

    func windowDidResize(_ notification: Notification) {
        table.sizeLastColumnToFit()
    }
}
