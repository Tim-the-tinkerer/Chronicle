import AppKit
import Foundation

/// The main thread raises this. The snapshot queue reads it.
private final class SnapshotCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() {
        lock.lock()
        raised = true
        lock.unlock()
    }

    func clear() {
        lock.lock()
        raised = false
        lock.unlock()
    }

    func isSet() -> Bool {
        lock.lock()
        let value = raised
        lock.unlock()
        return value
    }
}

final class AppModel: ObservableObject {
    @Published var libraries: [Library] = []
    @Published var selection: String?
    @Published var summaries: [SnapshotHead] = []
    /// New-byte figures for the version list. A missing parent file is measured once.
    @Published var glances: [String: VersionGlance] = [:]
    @Published var selectedSnapshotID: String?
    @Published var rows: [BrowserRow] = []
    /// Folders recorded in the selected version, including ones the file list hides.
    @Published var folderPaths: [String] = []
    @Published var filter = ""
    @Published var selectedPath: String?
    @Published var labelText = ""
    @Published var banner = ""
    @Published var progressPath = ""
    @Published var busy = false
    /// True only while a snapshot is the job that set `busy`. Restore and the other jobs do not.
    @Published var snapshotActive = false
    /// The user asked the running snapshot to stop. The button stays disabled until it finishes.
    @Published var snapshotStopping = false
    @Published var totals: VaultTotals?
    @Published var latestDate: Date?
    @Published var skipLine = ""
    @Published var selectedIsDirty = false
    @Published var thinningLog = ThinningLog.empty
    @Published var thinningReadable = true

    private let work = DispatchQueue(label: "com.tim.chronicle.work", qos: .userInitiated)
    private let watch = FolderWatch()
    private var timer: Timer?
    private var working = false
    private var dirty = Set<String>()
    private var dirtyGen: [String: Int] = [:]
    /// When an automatic check saved nothing. The schedule waits out that folder's interval
    /// instead of choosing it again every 20 seconds and starving the folders after it.
    private var lastAutomaticCheck: [String: Date] = [:]
    private var catchUpQueue: [String] = []
    /// Snapshot requests made while one is already running, in the order they were made.
    private var pendingUser: [(id: String, reason: String, verify: Bool)] = []
    /// A schedule check is reading the vault off the main thread.
    private var scheduling = false
    private let snapshotCancel = SnapshotCancel()
    private let defaultsKey = "chronicle.library"
    private let snapshotRootKey = "chronicle.snapshotRoot"
    private var started = false
    private var thinNote = ""
    /// Bumped whenever a newer version list is scheduled. An older load does not replace it.
    private var listEpoch = 0
    /// `refresh` was asked for while a job was running.
    private var refreshPending = false
    /// The folder whose versions are on screen. A switch clears that list immediately.
    private var shownLibrary: String?
    /// True once the selected version's folder list has been read, even when it is empty.
    private var foldersReady = false
    private var folderSnapshotID: String?

    var selectedLibrary: Library? {
        libraries.first { $0.id == selection }
    }

    func isDirty(_ id: String) -> Bool {
        dirty.contains(id)
    }

    var selectedRow: BrowserRow? {
        rows.first { $0.path == selectedPath }
    }

    var idleLine: String {
        guard let library = selectedLibrary else {
            return "Add a folder. Each version stores only what changed."
        }
        if !FileManager.default.fileExists(atPath: library.source) {
            return "The folder is missing."
        }
        if !FileManager.default.fileExists(atPath: library.vault), !SnapshotPlace.isReachable(library.vault) {
            return "Snapshots are unavailable. Plug the drive back in, or choose another place."
        }
        if library.policy == "manual" {
            return selectedIsDirty ? "Changes since the last version." : "Watching. Snapshots are manual."
        }
        if selectedIsDirty, let when = nextDate {
            return "Changes waiting. Next version \(TimeText.display(when))."
        }
        if selectedIsDirty { return "Changes waiting." }
        return "Watching. Nothing new since the last version."
    }

    var snapshotLocation: String {
        guard let library = selectedLibrary else { return "On this Mac" }
        if FileManager.default.fileExists(atPath: library.vault) {
            return library.vault
        }
        if SnapshotPlace.isReachable(library.vault) {
            return library.vault
        }
        return "Unavailable. The drive may be unplugged."
    }

    var nextDate: Date? {
        guard let library = selectedLibrary, let interval = Policy.seconds(library.policy) else { return nil }
        return (latestDate ?? Date()).addingTimeInterval(interval)
    }

    func start() {
        if started {
            refresh()
            return
        }
        started = true
        loadLibraries()
        if selection == nil {
            selection = UserDefaults.standard.string(forKey: defaultsKey)
        }
        if selection == nil || !libraries.contains(where: { $0.id == selection }) {
            selection = libraries.first?.id
        }
        watch.onChange = { [weak self] root in
            DispatchQueue.main.async { self?.markDirty(root) }
        }
        rewatch()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.tick()
        }
        refresh()
        // heal reads the vault. On a sleeping external drive that has to stay off the main thread.
        // It also thins old versions, so the list is loaded again after that finishes.
        let vaults = libraries.map { (name: $0.name, vault: $0.vault) }
        let nameEach = vaults.count > 1
        work.async {
            var thinned: [(name: String, result: PruneResult)] = []
            for item in vaults {
                let vault = URL(fileURLWithPath: item.vault)
                guard FileManager.default.fileExists(atPath: vault.path) else { continue }
                let result = (try? Vault.heal(vault)) ?? .none
                if result.count > 0 {
                    thinned.append((item.name, result))
                }
            }
            DispatchQueue.main.async {
                if !thinned.isEmpty {
                    self.thinNote = ThinText.report(thinned, nameEach: nameEach)
                    self.banner = self.thinNote
                }
                self.refresh()
                self.catchUp()
            }
        }
    }

    /// Edits made while the app was closed never produced a filesystem event.
    /// Save a version of each automatic folder when the fast check sees a change.
    private func catchUp() {
        let ids = libraries.compactMap { library -> String? in
            guard Policy.seconds(library.policy) != nil else { return nil }
            guard FileManager.default.fileExists(atPath: library.source) else { return nil }
            guard SnapshotPlace.isReachable(library.vault) else { return nil }
            return library.id
        }
        guard !ids.isEmpty else { return }
        work.async {
            DispatchQueue.main.async {
                self.catchUpQueue.append(contentsOf: ids)
                self.catchUpNext()
            }
        }
    }

    private func catchUpNext() {
        guard !working else { return }
        while let id = catchUpQueue.first {
            catchUpQueue.removeFirst()
            guard let library = libraries.first(where: { $0.id == id }),
                  Policy.seconds(library.policy) != nil,
                  FileManager.default.fileExists(atPath: library.source),
                  SnapshotPlace.isReachable(library.vault) else { continue }
            takeSnapshot(libraryID: id, reason: "catchup", verify: false) { [weak self] in
                self?.catchUpNext()
            }
            return
        }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = "Watch"
        panel.message = "Chronicle keeps every version of this folder, and stores only what changes."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.resolvingSymlinksInPath().path
        if libraries.contains(where: { PathGuard.standardized($0.source) == PathGuard.standardized(path) }) {
            banner = "That folder already has a history."
            return
        }
        guard let answer = askWhere(moving: false) else { return }
        let id = UUID().uuidString
        let name = url.lastPathComponent
        let sourceURL = URL(fileURLWithPath: path, isDirectory: true)
        let vault: URL
        switch answer {
        case .onThisMac:
            do {
                vault = try SnapshotPlace.locate(
                    name: name,
                    id: id,
                    onThisMacRoot: vaultsRoot(),
                    chosen: nil,
                    isVolume: false,
                    isEmpty: false,
                    isVault: false,
                    source: sourceURL,
                    current: nil
                )
            } catch {
                banner = error.localizedDescription
                return
            }
            UserDefaults.standard.removeObject(forKey: snapshotRootKey)
        case .remembered(let root):
            let child = SnapshotPlace.child(in: root, name: name)
            if let problem = placementProblem(child, source: sourceURL, current: nil) {
                banner = problem
                return
            }
            vault = child
        case .choose:
            guard let picked = pickSnapshotFolder() else { return }
            let flags = folderFlags(picked)
            do {
                vault = try SnapshotPlace.locate(
                    name: name,
                    id: id,
                    onThisMacRoot: vaultsRoot(),
                    chosen: picked,
                    isVolume: flags.isVolume,
                    isEmpty: flags.isEmpty,
                    isVault: flags.isVault,
                    source: sourceURL,
                    current: nil
                )
            } catch {
                banner = error.localizedDescription
                return
            }
            let root = SnapshotPlace.rememberedRoot(
                chosen: picked,
                isVolume: flags.isVolume,
                isEmpty: flags.isEmpty
            )
            UserDefaults.standard.set(root.path, forKey: snapshotRootKey)
        }
        let library = Library(
            id: id,
            name: name,
            source: path,
            vault: vault.path,
            policy: "quarter",
            added: TimeText.nowISO()
        )
        libraries.append(library)
        saveLibraries()
        selection = id
        UserDefaults.standard.set(id, forKey: defaultsKey)
        rewatch()
        takeSnapshot(libraryID: id, reason: "first", verify: false)
    }

    func removeSelectedLibrary() {
        guard let library = selectedLibrary else { return }
        if working {
            banner = "Chronicle is still finishing the last job."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Remove \(library.name)?"
        alert.informativeText = "The folder stays where it is. The history can stay on disk, or it can be deleted."
        alert.addButton(withTitle: "Remove from List")
        alert.addButton(withTitle: "Remove and Delete History")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.buttons[2].keyEquivalent = "\u{1b}"
        let response = alert.runModal()
        if response == .alertThirdButtonReturn { return }
        if working {
            banner = "Chronicle is still finishing the last job."
            return
        }
        let deleteHistory = response == .alertSecondButtonReturn
        let id = library.id
        libraries.removeAll { $0.id == id }
        dirty.remove(id)
        if selection == id {
            selection = libraries.first?.id
            UserDefaults.standard.set(selection, forKey: defaultsKey)
        }
        saveLibraries()
        rewatch()
        if deleteHistory {
            do {
                try Vault.removeVault(URL(fileURLWithPath: library.vault))
                banner = "Removed \(library.name) and its history."
            } catch {
                banner = "Removed \(library.name). \(error.localizedDescription)"
            }
        } else {
            banner = "Removed \(library.name). History is still on disk."
        }
        refresh()
    }

    func setPolicy(_ policy: String) {
        guard let id = selection, let index = libraries.firstIndex(where: { $0.id == id }) else { return }
        libraries[index].policy = policy
        saveLibraries()
    }

    func takeSnapshot(
        libraryID: String? = nil,
        reason: String = "manual",
        verify: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        let id = libraryID ?? selection
        guard let id, let library = libraries.first(where: { $0.id == id }) else {
            completion?()
            return
        }
        if working {
            // Stop is already winding this snapshot down. Queuing would start the next
            // folder the moment it ends.
            if snapshotStopping {
                return
            }
            if reason != "catchup" {
                pendingUser.append((id, reason, verify))
            }
            return
        }
        if !FileManager.default.fileExists(atPath: library.source) {
            banner = "The folder is missing."
            completion?()
            return
        }
        if !SnapshotPlace.isReachable(library.vault) {
            banner = "Snapshots are unavailable. Plug the drive back in, or choose another place."
            completion?()
            return
        }
        working = true
        busy = true
        snapshotActive = true
        snapshotStopping = false
        snapshotCancel.clear()
        progressPath = ""
        listEpoch += 1
        refreshPending = true
        let stampLabel = (libraryID == nil || libraryID == selection) && (reason == "manual" || reason == "first")
        let name = library.name
        if reason == "catchup" {
            banner = "Checking \(name)…"
        } else {
            banner = verify ? "Re-reading every file…" : "Reading the folder…"
        }
        let generation = dirtyGen[id] ?? 0
        let label = stampLabel ? labelText.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let source = URL(fileURLWithPath: library.source)
        let vault = URL(fileURLWithPath: library.vault)
        let cancelFlag = snapshotCancel
        var lastProgress = Date.distantPast
        work.async {
            do {
                let snap = try Vault.snapshot(
                    source: source,
                    vault: vault,
                    label: label,
                    reason: reason,
                    verify: verify,
                    progress: { path in
                        let now = Date()
                        if now.timeIntervalSince(lastProgress) < 0.08 { return }
                        lastProgress = now
                        DispatchQueue.main.async { self.progressPath = path }
                    },
                    isCancelled: { cancelFlag.isSet() }
                )
                let heads = try Vault.listHeads(vault)
                let shown = Vault.rowGlances(vault: vault, heads: heads)
                let totals = try Vault.totals(vault)
                let skip = (try? Vault.config(vault).skipNames.joined(separator: ", ")) ?? VaultConfig.defaultSkip.joined(separator: ", ")
                DispatchQueue.main.async {
                    // finishWork clears the flag. Read it first, or a late stop looks like a normal save.
                    let stoppedLate = cancelFlag.isSet()
                    let stillHere = self.selection == id
                    if stillHere { self.refreshPending = false }
                    self.finishWork()
                    if self.dirtyGen[id] == generation {
                        self.dirty.remove(id)
                    }
                    if snap == nil && (reason == "watch" || reason == "catchup") {
                        self.lastAutomaticCheck[id] = Date()
                    }
                    self.selectedIsDirty = self.dirty.contains(self.selection ?? "")
                    if stillHere {
                        self.shownLibrary = id
                        self.summaries = heads
                        self.glances = shown
                        self.totals = totals
                        self.latestDate = heads.first.flatMap { TimeText.parse($0.created) }
                        self.skipLine = skip
                        if stampLabel { self.labelText = "" }
                        if let snap {
                            self.loadRows(snap.id)
                        } else if let current = self.selectedSnapshotID, heads.contains(where: { $0.id == current }) {
                            self.loadRows(current)
                        } else if let first = heads.first {
                            self.loadRows(first.id)
                        } else {
                            self.rows = []
                            self.dropFolderList()
                            self.selectedSnapshotID = nil
                        }
                    }
                    if let snap {
                        var line = self.resultLine(snap)
                        if snap.pruned == 0, !self.thinNote.isEmpty {
                            line += " " + self.thinNote
                        }
                        self.thinNote = ""
                        if stoppedLate {
                            line += " Stop came after this version was saved."
                        }
                        self.banner = stillHere ? line : "\(name): \(line)"
                    } else if reason == "catchup" {
                        if self.banner.hasPrefix("Checking") || stoppedLate { self.banner = self.thinNote }
                    } else if stillHere {
                        self.banner = "Nothing changed."
                    } else if self.banner == "Reading the folder…" || stoppedLate {
                        self.banner = self.thinNote
                    }
                    if stoppedLate {
                        self.pendingUser.removeAll()
                        self.catchUpQueue.removeAll()
                    } else {
                        self.resumeWork(completion)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    let cancelled = (error as? ChronicleError)?.code == .snapshotCancelled
                    self.finishWork()
                    if cancelled {
                        self.banner = "Stopped. The version was not saved."
                        self.lastAutomaticCheck[id] = Date()
                        self.pendingUser.removeAll()
                        self.catchUpQueue.removeAll()
                    } else {
                        self.banner = error.localizedDescription
                        self.resumeWork(completion)
                    }
                }
            }
        }
    }

    /// Asks the running snapshot to stop before the version is published.
    func stopSnapshot() {
        guard snapshotActive, !snapshotStopping else {
            if !snapshotActive {
                banner = "No snapshot is running."
            }
            return
        }
        snapshotStopping = true
        snapshotCancel.raise()
        pendingUser.removeAll()
        catchUpQueue.removeAll()
        banner = "Stopping…"
    }

    private func resumeWork(_ completion: (() -> Void)?) {
        if !pendingUser.isEmpty {
            let pending = pendingUser.removeFirst()
            takeSnapshot(libraryID: pending.id, reason: pending.reason, verify: pending.verify, completion: completion)
            return
        }
        if let completion {
            completion()
            return
        }
        catchUpNext()
    }

    func refresh() {
        guard let library = selectedLibrary else {
            listEpoch += 1
            shownLibrary = nil
            summaries = []
            glances = [:]
            rows = []
            dropFolderList()
            selectedSnapshotID = nil
            selectedPath = nil
            totals = nil
            latestDate = nil
            skipLine = ""
            thinningLog = .empty
            thinningReadable = true
            return
        }
        // The previous folder's versions stay in `summaries` until this returns.
        // Clear them now so Delete and Restore cannot use that folder's ids with this one.
        if shownLibrary != library.id {
            shownLibrary = library.id
            summaries = []
            glances = [:]
            rows = []
            dropFolderList()
            selectedSnapshotID = nil
            selectedPath = nil
            totals = nil
            latestDate = nil
            thinningLog = .empty
            thinningReadable = true
        }
        if working {
            refreshPending = true
            return
        }
        let vault = URL(fileURLWithPath: library.vault)
        guard FileManager.default.fileExists(atPath: vault.path) else {
            listEpoch += 1
            summaries = []
            glances = [:]
            rows = []
            dropFolderList()
            selectedSnapshotID = nil
            selectedPath = nil
            totals = nil
            latestDate = nil
            skipLine = VaultConfig.defaultSkip.joined(separator: ", ")
            thinningLog = .empty
            thinningReadable = true
            return
        }
        listEpoch += 1
        let epoch = listEpoch
        let libraryID = library.id
        work.async {
            let heads = (try? Vault.listHeads(vault)) ?? []
            let shown = Vault.rowGlances(vault: vault, heads: heads)
            let totals = try? Vault.totals(vault)
            let skip = (try? Vault.config(vault).skipNames.joined(separator: ", ")) ?? VaultConfig.defaultSkip.joined(separator: ", ")
            let history = Vault.thinningHistory(vault)
            DispatchQueue.main.async {
                guard epoch == self.listEpoch, !self.working, self.selection == libraryID else { return }
                self.shownLibrary = libraryID
                self.summaries = heads
                self.glances = shown
                self.totals = totals
                self.latestDate = heads.first.flatMap { TimeText.parse($0.created) }
                self.skipLine = skip
                self.thinningLog = history.log
                self.thinningReadable = history.readable
                if let current = self.selectedSnapshotID, heads.contains(where: { $0.id == current }) {
                    self.loadRows(current)
                } else if let first = heads.first {
                    self.loadRows(first.id)
                } else {
                    self.rows = []
                    self.dropFolderList()
                    self.selectedSnapshotID = nil
                }
            }
        }
    }

    func loadRows(_ id: String) {
        guard let library = selectedLibrary else { return }
        selectedSnapshotID = id
        dropFolderList()
        let libraryID = library.id
        let vault = URL(fileURLWithPath: library.vault)
        work.async {
            let snap: Snapshot
            do {
                snap = try Vault.load(vault, id)
            } catch {
                DispatchQueue.main.async {
                    guard self.selection == libraryID, self.selectedSnapshotID == id else { return }
                    self.rows = []
                    self.folderPaths = []
                    self.folderSnapshotID = id
                    self.foldersReady = true
                    if !self.busy { self.banner = error.localizedDescription }
                }
                return
            }
            let basis = Vault.compared(vault: vault, to: snap)
            let names = Set((try? Vault.config(vault).skipNames) ?? VaultConfig.defaultSkip)
            let warnings = snap.warnings(skipNames: names)
            let rows = Diff.rows(
                current: snap.files,
                parent: basis.parent?.files,
                comparable: basis.comparable,
                carried: warnings.carried,
                unread: warnings.unread
            )
            let folders = snap.files.compactMap { $0.kind == "dir" ? $0.path : nil }.sorted()
            DispatchQueue.main.async {
                guard self.selection == libraryID, self.selectedSnapshotID == id else { return }
                self.rows = rows
                self.folderPaths = folders
                self.folderSnapshotID = id
                self.foldersReady = true
                if let path = self.selectedPath, !rows.contains(where: { $0.path == path }) {
                    self.selectedPath = nil
                }
            }
        }
    }

    func restoreSelected() {
        guard !working, let library = selectedLibrary, let id = selectedSnapshotID else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Restore Here"
        panel.message = "Chronicle writes a new folder here. The watched folder is left alone."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !working else {
            banner = "Chronicle is still finishing the last job."
            return
        }
        let stamp = Self.folderStamp(TimeText.parse(summaries.first { $0.id == id }?.created ?? "") ?? Date())
        let dest = uniqueDestination(url, name: "\(library.name) \(stamp)")
        let vault = URL(fileURLWithPath: library.vault)
        begin("Restoring…")
        work.async {
            do {
                try Vault.restore(vault: vault, snapshot: id, dest: dest, allowInsideSource: false)
                DispatchQueue.main.async {
                    self.finishWork()
                    self.banner = "Restored to \(dest.path)"
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            } catch {
                DispatchQueue.main.async {
                    self.finishWork()
                    self.banner = error.localizedDescription
                }
            }
        }
    }

    func restoreSelectedFile() {
        guard !working, let library = selectedLibrary, let id = selectedSnapshotID, let row = selectedRow else {
            banner = "Choose a file in this version."
            return
        }
        if row.kind == "dir" {
            banner = "Choose a file to restore."
            return
        }
        if row.change == "unread" {
            banner = "Chronicle could not read that file, so this version does not have it."
            return
        }
        if row.change == "removed" {
            banner = "That file is gone in this version. Restore it from the previous one."
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (row.path as NSString).lastPathComponent
        panel.prompt = "Restore"
        panel.message = "The watched folder is left alone."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !working else {
            banner = "Chronicle is still finishing the last job."
            return
        }
        let vault = URL(fileURLWithPath: library.vault)
        let path = row.path
        begin("Restoring \(path)…")
        work.async {
            do {
                try Vault.restoreFile(vault: vault, snapshot: id, path: path, dest: url, allowInsideSource: false)
                DispatchQueue.main.async {
                    self.finishWork()
                    self.banner = "Restored \(path)"
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                DispatchQueue.main.async {
                    self.finishWork()
                    self.banner = error.localizedDescription
                }
            }
        }
    }

    func restoreSelectedDirectory() {
        guard !working else {
            banner = "Chronicle is still finishing the last job."
            return
        }
        guard let library = selectedLibrary, let id = selectedSnapshotID else {
            banner = "Choose a folder in this version."
            return
        }
        guard foldersReady, folderSnapshotID == id else {
            banner = "The folder list is still loading."
            return
        }
        guard !folderPaths.isEmpty else {
            banner = "This version has no folders. Restore Version writes the whole folder."
            return
        }
        let vault = URL(fileURLWithPath: library.vault)
        let snapshot = id
        let paths = folderPaths
        let preferred = RestoreTarget.preferred(row: selectedRow, folders: paths)
        guard let path = FolderPickPanel(paths: paths, preferred: preferred).run() else { return }
        guard !working else {
            banner = "Chronicle is still finishing the last job."
            return
        }
        guard paths.contains(path), RelPath.isSafe(path) else {
            banner = "That folder is not in this version."
            return
        }
        let name = (path as NSString).lastPathComponent
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Restore Here"
        panel.message = "Chronicle creates a new folder named \"\(name)\" here and puts the saved files inside it. The watched folder is left alone."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !working else {
            banner = "Chronicle is still finishing the last job."
            return
        }
        let dest = uniqueDestination(url, name: name)
        begin("Restoring \(name)…")
        work.async {
            do {
                try Vault.restoreDirectory(vault: vault, snapshot: snapshot, path: path, dest: dest, allowInsideSource: false)
                DispatchQueue.main.async {
                    self.finishWork()
                    self.banner = "Restored to \(dest.path)"
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            } catch {
                DispatchQueue.main.async {
                    self.finishWork()
                    self.banner = error.localizedDescription
                }
            }
        }
    }

    private func dropFolderList() {
        folderPaths = []
        foldersReady = false
        folderSnapshotID = nil
    }

    func deleteSelectedSnapshot() {
        guard !working, let library = selectedLibrary, let id = selectedSnapshotID else { return }
        let alert = NSAlert()
        alert.messageText = "Delete this version?"
        alert.informativeText = "Chunks that no other version uses are removed. The watched folder is left alone."
        alert.addButton(withTitle: "Delete Version")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.buttons[1].keyEquivalent = "\u{1b}"
        if alert.runModal() != .alertFirstButtonReturn { return }
        guard !working else {
            banner = "Chronicle is still finishing the last job."
            return
        }
        let vault = URL(fileURLWithPath: library.vault)
        begin("Deleting…")
        work.async {
            do {
                let freed = try Vault.delete(vault: vault, id: id)
                DispatchQueue.main.async {
                    self.finishWork()
                    self.banner = "Deleted the version. Freed \(ByteText.string(freed))."
                }
            } catch {
                DispatchQueue.main.async {
                    self.finishWork()
                    self.banner = error.localizedDescription
                }
            }
        }
    }

    func cleanSelected() {
        guard !working, let library = selectedLibrary else { return }
        let vault = URL(fileURLWithPath: library.vault)
        begin("Cleaning unused chunks…")
        work.async {
            do {
                let cleaned = try Vault.clean(vault)
                DispatchQueue.main.async {
                    self.finishWork()
                    if cleaned.thinning.count > 0 {
                        self.banner = ThinText.sentence(
                            names: ThinText.names(cleaned.thinning),
                            freed: cleaned.freed,
                            complete: cleaned.thinning.complete
                        )
                    } else {
                        self.banner = "Freed \(ByteText.string(cleaned.freed))."
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.finishWork()
                    self.banner = error.localizedDescription
                }
            }
        }
    }

    func revealSource() {
        guard let library = selectedLibrary else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: library.source)
    }

    func revealVault() {
        guard let library = selectedLibrary else { return }
        if !FileManager.default.fileExists(atPath: library.vault) {
            banner = SnapshotPlace.isReachable(library.vault)
                ? "That history is not on disk yet."
                : "Snapshots are unavailable. Plug the drive back in, or choose another place."
            return
        }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: library.vault)
    }

    func chooseSnapshotPlace() {
        if working {
            banner = "Chronicle is still finishing the last job."
            return
        }
        guard let library = selectedLibrary else {
            rememberDefaultOnly()
            return
        }
        if !FileManager.default.fileExists(atPath: library.vault) || !SnapshotPlace.isReachable(library.vault) {
            banner = "Snapshots are unavailable. Plug the drive back in."
            return
        }
        guard let answer = askWhere(moving: true) else { return }
        let sourceURL = URL(fileURLWithPath: library.source, isDirectory: true)
        let current = URL(fileURLWithPath: library.vault, isDirectory: true)
        let dest: URL
        switch answer {
        case .onThisMac:
            do {
                dest = try SnapshotPlace.locate(
                    name: library.name,
                    id: library.id,
                    onThisMacRoot: vaultsRoot(),
                    chosen: nil,
                    isVolume: false,
                    isEmpty: false,
                    isVault: false,
                    source: sourceURL,
                    current: current
                )
            } catch {
                banner = error.localizedDescription
                return
            }
        case .remembered(let root):
            let child = SnapshotPlace.child(in: root, name: library.name)
            if let problem = placementProblem(child, source: sourceURL, current: current) {
                banner = problem
                return
            }
            dest = child
        case .choose:
            guard let picked = pickSnapshotFolder() else { return }
            let flags = folderFlags(picked)
            do {
                dest = try SnapshotPlace.locate(
                    name: library.name,
                    id: library.id,
                    onThisMacRoot: vaultsRoot(),
                    chosen: picked,
                    isVolume: flags.isVolume,
                    isEmpty: flags.isEmpty,
                    isVault: flags.isVault,
                    source: sourceURL,
                    current: current
                )
            } catch {
                banner = error.localizedDescription
                return
            }
            let root = SnapshotPlace.rememberedRoot(
                chosen: picked,
                isVolume: flags.isVolume,
                isEmpty: flags.isEmpty
            )
            UserDefaults.standard.set(root.path, forKey: snapshotRootKey)
        }
        if samePlace(dest, current) {
            banner = "Snapshots are already stored there."
            return
        }
        guard !working else {
            banner = "Chronicle is still finishing the last job."
            return
        }
        let id = library.id
        begin("Moving snapshots…")
        work.async {
            do {
                try Vault.relocate(from: current, to: dest) {
                    var failure: String?
                    DispatchQueue.main.sync {
                        guard let index = self.libraries.firstIndex(where: { $0.id == id }) else {
                            failure = "That folder is no longer in the list. The original history was left where it is."
                            return
                        }
                        let previous = self.libraries[index].vault
                        self.libraries[index].vault = dest.path
                        do {
                            try self.writeLibraries()
                        } catch {
                            self.libraries[index].vault = previous
                            failure = "Could not save the new location. The original history was left where it is."
                        }
                    }
                    if let failure {
                        throw ChronicleError.fail(failure)
                    }
                }
                DispatchQueue.main.async {
                    self.finishWork()
                    self.banner = "Snapshots are in \(dest.path)."
                }
            } catch {
                DispatchQueue.main.async {
                    self.finishWork()
                    self.banner = error.localizedDescription
                }
            }
        }
    }

    func verifySelected() {
        guard let library = selectedLibrary else { return }
        if working {
            banner = "Chronicle is still finishing the last job."
            return
        }
        let vault = URL(fileURLWithPath: library.vault)
        begin("Checking history…")
        var lastProgress = Date.distantPast
        work.async {
            do {
                let report = try Vault.verifyHistory(vault: vault) { path in
                    let now = Date()
                    if now.timeIntervalSince(lastProgress) < 0.08 { return }
                    lastProgress = now
                    DispatchQueue.main.async { self.progressPath = path }
                }
                DispatchQueue.main.async {
                    self.finishWork()
                    self.banner = report.summary
                    if !report.problems.isEmpty {
                        self.presentVerify(report)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.finishWork()
                    self.banner = error.localizedDescription
                }
            }
        }
    }

    private func presentVerify(_ report: HistoryCheck) {
        let alert = NSAlert()
        alert.messageText = report.summary
        alert.informativeText = report.detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func resultLine(_ snap: Snapshot) -> String {
        let stats = snap.stats
        let body: String
        if stats.newChunkBytes == 0 && stats.addedFiles == 0 && stats.changedFiles == 0 && stats.removedFiles == 0 {
            body = "Nothing new. The folder is \(ByteText.string(stats.logicalBytes))."
        } else {
            body = "\(ByteText.string(stats.newChunkBytes)) new. A full copy would have been \(ByteText.string(stats.logicalBytes))."
        }
        var line = body
        if let status = stats.statusLine {
            line = "\(status). \(body)"
        }
        if snap.pruned > 0 {
            line += " " + ThinText.sentence(
                names: ThinText.names(snap.pruneDetail),
                freed: snap.pruneDetail.freed,
                complete: snap.pruneDetail.complete
            )
        }
        return line
    }

    private func tick() {
        guard !working, !scheduling else { return }
        let now = Date()
        let candidates = libraries.compactMap { library -> (id: String, source: String, vault: String, interval: TimeInterval, checked: Date?)? in
            guard dirty.contains(library.id), let interval = Policy.seconds(library.policy) else { return nil }
            return (library.id, library.source, library.vault, interval, lastAutomaticCheck[library.id])
        }
        guard !candidates.isEmpty else { return }
        scheduling = true
        work.async {
            var due: [(id: String, interval: TimeInterval, latest: Date?, checked: Date?)] = []
            for item in candidates {
                if !FileManager.default.fileExists(atPath: item.source) { continue }
                if !SnapshotPlace.isReachable(item.vault) { continue }
                let latest = Vault.latestDate(URL(fileURLWithPath: item.vault))
                due.append((item.id, item.interval, latest, item.checked))
            }
            let chosen = Self.nextDue(due, now: now)
            DispatchQueue.main.async {
                self.scheduling = false
                guard let chosen, !self.working, self.dirty.contains(chosen) else { return }
                self.takeSnapshot(libraryID: chosen, reason: "watch", verify: false)
            }
        }
    }

    /// The first folder whose own interval has passed since its latest version or its last empty check.
    static func nextDue(
        _ items: [(id: String, interval: TimeInterval, latest: Date?, checked: Date?)],
        now: Date
    ) -> String? {
        for item in items {
            let recent = [item.latest, item.checked].compactMap { $0 }.max()
            if let recent, now.timeIntervalSince(recent) < item.interval { continue }
            return item.id
        }
        return nil
    }

    private func markDirty(_ root: String) {
        let standard = PathGuard.canonical(root)
        guard let library = libraries.first(where: { PathGuard.canonical($0.source) == standard }) else { return }
        dirtyGen[library.id, default: 0] += 1
        dirty.insert(library.id)
        if library.id == selection { selectedIsDirty = true }
    }

    private func rewatch() {
        watch.setRoots(libraries.map(\.source))
    }

    private func begin(_ message: String) {
        working = true
        busy = true
        progressPath = ""
        banner = message
        listEpoch += 1
        refreshPending = true
    }

    private func finishWork() {
        working = false
        busy = false
        snapshotActive = false
        snapshotStopping = false
        snapshotCancel.clear()
        progressPath = ""
        if refreshPending {
            refreshPending = false
            refresh()
        }
    }

    private enum PlaceAnswer {
        case onThisMac
        case remembered(URL)
        case choose
    }

    private func askWhere(moving: Bool) -> PlaceAnswer? {
        let alert = NSAlert()
        alert.messageText = moving
            ? "Where should these snapshots move?"
            : "Where should Chronicle keep the snapshots?"
        alert.informativeText = moving
            ? "The history moves. The watched folder stays where it is."
            : "On this Mac keeps them with Chronicle. A folder or another drive leaves the watched folder where it is."
        if let remembered = rememberedRootURL() {
            alert.addButton(withTitle: "On \(placeTitle(remembered))")
            alert.addButton(withTitle: "On this Mac")
            alert.addButton(withTitle: "Choose Folder or Drive…")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[3].keyEquivalent = "\u{1b}"
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .remembered(remembered)
            case .alertSecondButtonReturn: return .onThisMac
            case .alertThirdButtonReturn: return .choose
            default: return nil
            }
        }
        alert.addButton(withTitle: "On this Mac")
        alert.addButton(withTitle: "Choose Folder or Drive…")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[2].keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .onThisMac
        case .alertSecondButtonReturn: return .choose
        default: return nil
        }
    }

    private func rememberDefaultOnly() {
        guard let answer = askWhere(moving: false) else { return }
        switch answer {
        case .onThisMac:
            UserDefaults.standard.removeObject(forKey: snapshotRootKey)
            banner = "New folders will keep their history on this Mac."
        case .remembered:
            banner = "New folders will keep their history there."
        case .choose:
            guard let picked = pickSnapshotFolder() else { return }
            let flags = folderFlags(picked)
            if flags.isVault {
                banner = "That folder is already a Chronicle history."
                return
            }
            let root = SnapshotPlace.rememberedRoot(
                chosen: picked,
                isVolume: flags.isVolume,
                isEmpty: flags.isEmpty
            )
            UserDefaults.standard.set(root.path, forKey: snapshotRootKey)
            banner = "New folders will keep their history in \(root.path)."
        }
    }

    private func pickSnapshotFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Store Here"
        panel.message = "Store the snapshots in this folder, or on this drive. The watched folder is not moved."
        if let remembered = rememberedRootURL() {
            panel.directoryURL = remembered
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func rememberedRootURL() -> URL? {
        guard let raw = UserDefaults.standard.string(forKey: snapshotRootKey), !raw.isEmpty else { return nil }
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasPrefix("/Volumes/") {
            guard SnapshotPlace.isReachable(path) else { return nil }
            return url
        }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return url
    }

    private func placeTitle(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/")
            if parts.count >= 2 {
                let volumeRoot = URL(fileURLWithPath: "/Volumes/\(parts[1])", isDirectory: true)
                if let name = try? volumeRoot.resourceValues(forKeys: [.volumeNameKey]).volumeName, !name.isEmpty {
                    return name
                }
                return String(parts[1])
            }
        }
        let name = url.lastPathComponent
        return name.isEmpty ? "this Mac" : name
    }

    private func folderFlags(_ url: URL) -> (isVolume: Bool, isEmpty: Bool, isVault: Bool) {
        let values = try? url.resourceValues(forKeys: [.isVolumeKey])
        let isVolume = values?.isVolume == true
        let format = (try? String(contentsOf: url.appendingPathComponent("FORMAT"), encoding: .utf8)) ?? ""
        let isVault = format.trimmingCharacters(in: .whitespacesAndNewlines) == AppInfo.format
        let isEmpty: Bool
        if let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            isEmpty = items.allSatisfy { $0.lastPathComponent == ".DS_Store" }
        } else {
            isEmpty = false
        }
        return (isVolume, isEmpty, isVault)
    }

    private func placementProblem(_ vault: URL, source: URL, current: URL?) -> String? {
        let vaultPath = vault.resolvingSymlinksInPath().standardizedFileURL.path
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        if vaultPath == sourcePath || PathGuard.isInside(vaultPath, of: sourcePath) || PathGuard.isInside(sourcePath, of: vaultPath) {
            return "Choose a place outside the watched folder."
        }
        if let current {
            let currentPath = current.resolvingSymlinksInPath().standardizedFileURL.path
            if vaultPath == currentPath {
                return "Snapshots are already stored there."
            }
            if PathGuard.isInside(vaultPath, of: currentPath) || PathGuard.isInside(currentPath, of: vaultPath) {
                return "Choose a place outside the current snapshots."
            }
        }
        return nil
    }

    private func samePlace(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func vaultsRoot() -> URL {
        let root = supportDirectory().appendingPathComponent("Vaults", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chronicle", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func librariesURL() -> URL {
        supportDirectory().appendingPathComponent("libraries.json")
    }

    private func loadLibraries() {
        guard let libraries = try? JSONFile.read([Library].self, from: librariesURL()) else { return }
        self.libraries = libraries
    }

    private func saveLibraries() {
        try? writeLibraries()
    }

    private func writeLibraries() throws {
        try JSONFile.write(libraries, to: librariesURL(), pretty: true)
    }

    private func uniqueDestination(_ parent: URL, name: String) -> URL {
        var url = parent.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = parent.appendingPathComponent("\(name) \(number)")
            number += 1
        }
        return url
    }

    private static func folderStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.string(from: date)
    }
}
