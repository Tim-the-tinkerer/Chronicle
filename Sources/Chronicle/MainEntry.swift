import AppKit
import SwiftUI

@main
struct MainEntry {
    static func main() {
        let args = CommandLine.arguments
        let userArgs = args.dropFirst().filter { !$0.hasPrefix("-psn_") }
        if userArgs.contains("--self-test") {
            if let error = SelfTest.run() {
                fputs("SELF-TEST FAILED: \(error)\n", stderr)
                exit(1)
            }
            print("SELF-TEST OK")
            exit(0)
        }
        if userArgs.contains("--help") || userArgs.contains("-h") {
            print(CLI.help)
            exit(0)
        }
        if userArgs.contains("--version") {
            print("\(AppInfo.name) \(AppInfo.version) (\(AppInfo.build))")
            exit(0)
        }
        if !userArgs.isEmpty {
            CLI.run(Array(args))
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let model = AppModel()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        installStatusItem()
        model.start()
        showMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitting = true
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Closing the window hides it. The schedule stays, and the Dock icon leaves.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if quitting { return true }
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(rootView: ContentView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Chronicle"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.windowBackground
        window.contentView = hosting
        window.minSize = NSSize(width: 920, height: 580)
        window.center()
        window.setFrameAutosaveName("ChronicleMain")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "Chronicle.StatusItem"
        if let button = item.button {
            button.image = statusImage()
            button.image?.isTemplate = true
            button.toolTip = "Chronicle"
            button.setAccessibilityTitle("Chronicle")
            button.setAccessibilityHelp("Watched folders keep their schedule while the window is closed.")
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func statusImage() -> NSImage {
        let symbol = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Chronicle")
        let base = symbol ?? NSImage(size: NSSize(width: 18, height: 18))
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = true
        return image
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu == statusItem?.menu else { return }
        menu.removeAllItems()
        let show = NSMenuItem(title: "Show Chronicle", action: #selector(showWindow(_:)), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        if model.snapshotActive {
            let title = model.snapshotStopping ? "Stopping…" : "Stop Snapshot"
            let stop = NSMenuItem(title: title, action: #selector(stopSnapshot(_:)), keyEquivalent: "")
            stop.target = self
            stop.isEnabled = !model.snapshotStopping
            menu.addItem(stop)
        } else if model.busy {
            let busy = NSMenuItem(title: model.banner.isEmpty ? "Saving a version…" : model.banner, action: nil, keyEquivalent: "")
            busy.isEnabled = false
            menu.addItem(busy)
        }
        if model.libraries.isEmpty {
            let empty = NSMenuItem(title: "No folders yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for library in model.libraries {
                let status = BarStatus.line(
                    name: library.name,
                    policy: library.policy,
                    dirty: model.isDirty(library.id),
                    sourceExists: FileManager.default.fileExists(atPath: library.source),
                    vaultReachable: SnapshotPlace.isReachable(library.vault)
                )
                let info = NSMenuItem(title: status.title, action: nil, keyEquivalent: "")
                info.isEnabled = false
                menu.addItem(info)
                let snap = NSMenuItem(title: "Snapshot \(library.name)", action: #selector(snapshotLibrary(_:)), keyEquivalent: "")
                snap.target = self
                snap.representedObject = library.id
                snap.isEnabled = status.canSnapshot && !model.busy
                menu.addItem(snap)
            }
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Chronicle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
    }

    @objc private func showWindow(_ sender: Any?) {
        showMainWindow()
    }

    @objc private func snapshotLibrary(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.takeSnapshot(libraryID: id, reason: "manual", verify: false)
    }

    @objc private func addFolder(_ sender: Any?) { model.addFolder() }
    @objc private func snapshot(_ sender: Any?) { model.takeSnapshot() }
    @objc private func stopSnapshot(_ sender: Any?) { model.stopSnapshot() }
    @objc private func reread(_ sender: Any?) { model.takeSnapshot(reason: "manual", verify: true) }
    @objc private func restore(_ sender: Any?) { model.restoreSelected() }
    @objc private func restoreFile(_ sender: Any?) { model.restoreSelectedFile() }
    @objc private func restoreDirectory(_ sender: Any?) { model.restoreSelectedDirectory() }
    @objc private func deleteVersion(_ sender: Any?) { model.deleteSelectedSnapshot() }
    @objc private func clean(_ sender: Any?) { model.cleanSelected() }
    @objc private func verifyHistory(_ sender: Any?) { model.verifySelected() }
    @objc private func revealFolder(_ sender: Any?) { model.revealSource() }
    @objc private func revealHistory(_ sender: Any?) { model.revealVault() }
    @objc private func storeSnapshots(_ sender: Any?) { model.chooseSnapshotPlace() }

    @objc private func showAbout(_ sender: Any?) {
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: AppInfo.name,
            .version: AppInfo.version,
            .applicationVersion: "Version \(AppInfo.version) (\(AppInfo.build))",
            .credits: NSAttributedString(
                string: "A personal time machine. Each version stores only what changed.",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ),
        ]
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let about = appMenu.addItem(withTitle: "About Chronicle", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Chronicle", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Chronicle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        let add = fileMenu.addItem(withTitle: "Add Folder…", action: #selector(addFolder(_:)), keyEquivalent: "o")
        add.target = self
        let snap = fileMenu.addItem(withTitle: "Take Snapshot", action: #selector(snapshot(_:)), keyEquivalent: "s")
        snap.target = self
        let rereadItem = fileMenu.addItem(withTitle: "Re-read Every File", action: #selector(reread(_:)), keyEquivalent: "s")
        rereadItem.keyEquivalentModifierMask = [.command, .option]
        rereadItem.target = self
        let stopItem = fileMenu.addItem(withTitle: "Stop Snapshot", action: #selector(stopSnapshot(_:)), keyEquivalent: ".")
        stopItem.target = self
        fileMenu.addItem(.separator())
        let restoreItem = fileMenu.addItem(withTitle: "Restore Version…", action: #selector(restore(_:)), keyEquivalent: "r")
        restoreItem.keyEquivalentModifierMask = [.command, .shift]
        restoreItem.target = self
        let fileRestore = fileMenu.addItem(withTitle: "Restore File…", action: #selector(restoreFile(_:)), keyEquivalent: "e")
        fileRestore.target = self
        let folderRestore = fileMenu.addItem(withTitle: "Restore Folder…", action: #selector(restoreDirectory(_:)), keyEquivalent: "e")
        folderRestore.keyEquivalentModifierMask = [.command, .shift]
        folderRestore.target = self
        let deleteItem = fileMenu.addItem(withTitle: "Delete Version…", action: #selector(deleteVersion(_:)), keyEquivalent: "\u{8}")
        deleteItem.target = self
        fileMenu.addItem(.separator())
        let verifyItem = fileMenu.addItem(withTitle: "Verify History", action: #selector(verifyHistory(_:)), keyEquivalent: "")
        verifyItem.target = self
        let cleanItem = fileMenu.addItem(withTitle: "Clean Unused Chunks", action: #selector(clean(_:)), keyEquivalent: "")
        cleanItem.target = self
        let showFolder = fileMenu.addItem(withTitle: "Show Watched Folder", action: #selector(revealFolder(_:)), keyEquivalent: "")
        showFolder.target = self
        let showHistory = fileMenu.addItem(withTitle: "Show History", action: #selector(revealHistory(_:)), keyEquivalent: "")
        showHistory.target = self
        let store = fileMenu.addItem(withTitle: "Store Snapshots…", action: #selector(storeSnapshots(_:)), keyEquivalent: "")
        store.target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    /// AppKit asks this for every item whose target is the delegate. Other actions stay enabled.
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(stopSnapshot(_:)) {
            return model.snapshotActive && !model.snapshotStopping
        }
        if menuItem.action == #selector(snapshotLibrary(_:)) {
            guard let id = menuItem.representedObject as? String,
                  let library = model.libraries.first(where: { $0.id == id }) else { return false }
            let status = BarStatus.line(
                name: library.name,
                policy: library.policy,
                dirty: model.isDirty(library.id),
                sourceExists: FileManager.default.fileExists(atPath: library.source),
                vaultReachable: SnapshotPlace.isReachable(library.vault)
            )
            return status.canSnapshot && !model.busy
        }
        return true
    }
}
