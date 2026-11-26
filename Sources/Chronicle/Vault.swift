import Darwin
import Foundation

private struct WalkItem {
    var relative: String
    var kind: String
    var mode: UInt32
    var mtimeNS: Int64
    var size: Int64
    var linkTarget: String?
    var absolute: String
}

private struct StatInfo {
    var kind: String
    var mode: UInt32
    var mtimeNS: Int64
    var size: Int64
}

private final class SkipBox {
    var paths: [String] = []
}

private final class ChunkAccum {
    var chunks: [String] = []
    var lengths: [Int] = []
    var newBytes: Int64 = 0
    var reusedBytes: Int64 = 0

    func reset() {
        chunks.removeAll(keepingCapacity: true)
        lengths.removeAll(keepingCapacity: true)
        newBytes = 0
        reusedBytes = 0
    }
}

/// `fsync` submits bytes to the drive. On macOS it can return while they still sit in the drive cache.
/// One `F_FULLFSYNC` flushes that whole cache, so it runs once, on the version file, just before the rename.
private enum Durable {
    static func sync(_ path: String) throws {
        let fd = open(path, O_RDONLY)
        if fd < 0 {
            throw ChronicleError.fail(String(cString: strerror(errno)))
        }
        let result = fsync(fd)
        let saved = errno
        close(fd)
        if result != 0 {
            throw ChronicleError.fail(String(cString: strerror(saved)))
        }
    }

    static func force(_ path: String) throws {
        let fd = open(path, O_RDONLY)
        if fd < 0 {
            throw ChronicleError.fail(String(cString: strerror(errno)))
        }
        let result = fcntl(fd, F_FULLFSYNC)
        let saved = errno
        close(fd)
        if result != 0 {
            throw ChronicleError.fail(String(cString: strerror(saved)))
        }
    }
}

/// Writes bytes and fsyncs them before the final name exists.
/// The directories that hold that name are fsynced later, before the version file is published.
private func installDurable(_ encoded: Data, at url: URL, noun: String, names: inout Set<String>) throws {
    let directory = url.deletingLastPathComponent()
    let partial = directory.appendingPathComponent(url.lastPathComponent + ".partial")
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoded.write(to: partial, options: .atomic)
        try Durable.sync(partial.path)
    } catch {
        try? FileManager.default.removeItem(at: partial)
        let detail = (error as? ChronicleError)?.message ?? error.localizedDescription
        throw ChronicleError.fail("Could not store \(noun) (\(detail)).")
    }
    var reason = ""
    let wrote = partial.path.withCString { source in
        url.path.withCString { dest in
            if rename(source, dest) == 0 { return true }
            reason = String(cString: strerror(errno))
            return false
        }
    }
    if !wrote {
        try? FileManager.default.removeItem(at: partial)
        throw ChronicleError.fail("Could not store \(noun) (\(reason)).")
    }
    names.insert(directory.path)
    let parent = directory.deletingLastPathComponent().path
    if parent != directory.path { names.insert(parent) }
}

/// True when the path is a regular file larger than a stored chunk or directory record can be.
private func regularFileIsLargerThan(_ url: URL, _ limit: Int) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values?.isRegularFile == true, let size = values?.fileSize else { return false }
    return size > limit
}

private final class ChunkStore {
    let root: URL
    private var known = Set<String>()
    private var pendingNames = Set<String>()
    private(set) var created: [String] = []

    init(root: URL) {
        self.root = root
    }

    func put(_ data: Data) throws -> (hash: String, isNew: Bool) {
        let hash = Digest.sha256(data)
        if known.contains(hash) { return (hash, false) }
        let url = chunkURL(hash)
        // The bytes were just hashed. Reading the stored file back, to decompress
        // and hash it again, doubles a re-read. Verify History is that check.
        // A missing file is written. A file that is already there is reused as it is.
        if FileManager.default.fileExists(atPath: url.path) {
            known.insert(hash)
            return (hash, false)
        }
        try store(ChunkCodec.encode(data), at: url, hash: hash, track: true)
        known.insert(hash)
        return (hash, true)
    }

    func flushNames() throws {
        for path in pendingNames.sorted() {
            do {
                try Durable.sync(path)
            } catch {
                let detail = (error as? ChronicleError)?.message ?? error.localizedDescription
                throw ChronicleError.fail("Could not make the history durable (\(detail)).")
            }
        }
        pendingNames.removeAll()
    }

    /// Moves a damaged chunk aside so the next re-read sees it as missing and writes a good copy.
    /// An older `.damaged` file is removed first. `rename` will not replace it, and the bad chunk would stay in use.
    func quarantine(_ hash: String) {
        let url = chunkURL(hash)
        let damaged = url.deletingLastPathComponent().appendingPathComponent(hash + ".damaged")
        if FileManager.default.fileExists(atPath: damaged.path) {
            unlink(damaged.path)
        }
        _ = url.path.withCString { source in
            damaged.path.withCString { dest in
                rename(source, dest)
            }
        }
    }

    private func store(_ encoded: Data, at url: URL, hash: String, track: Bool) throws {
        try installDurable(encoded, at: url, noun: "a chunk", names: &pendingNames)
        if track { created.append(hash) }
    }

    /// `unread` is a failed read. The file stays. `damaged` means the bytes were read
    /// and the hash did not match, or the chunk would not decompress.
    func check(_ hash: String) -> String {
        let url = chunkURL(hash)
        if !FileManager.default.fileExists(atPath: url.path) { return "missing" }
        // A file this large cannot be a valid chunk. Reading it would fill memory.
        if regularFileIsLargerThan(url, ChunkCodec.maxFileBytes) { return "damaged" }
        let raw: Data
        do {
            raw = try Data(contentsOf: url)
        } catch {
            return "unread"
        }
        do {
            let data = try ChunkCodec.decode(raw)
            if Digest.sha256(data) != hash { return "damaged" }
            return "ok"
        } catch {
            return "damaged"
        }
    }

    func read(_ hash: String) throws -> Data {
        guard Digest.isHash(hash) else { throw ChronicleError.fail("A chunk id is not a SHA-256.") }
        let url = chunkURL(hash)
        if regularFileIsLargerThan(url, ChunkCodec.maxFileBytes) {
            throw ChronicleError.fail("A chunk is larger than Chronicle allows.")
        }
        let raw = try Data(contentsOf: url)
        let data = try ChunkCodec.decode(raw)
        if Digest.sha256(data) != hash {
            throw ChronicleError.fail("Damaged chunk \(hash.prefix(12)).")
        }
        return data
    }

    func discardNew() {
        for hash in created {
            try? FileManager.default.removeItem(at: chunkURL(hash))
        }
        created.removeAll()
    }

    private func chunkURL(_ hash: String) -> URL {
        let shard = String(hash.prefix(2))
        return root.appendingPathComponent("chunks").appendingPathComponent(shard).appendingPathComponent(hash)
    }
}

/// A directory listing, named by the SHA-256 of its canonical JSON and stored like a chunk.
private final class TreeStore {
    let root: URL
    private var known = Set<String>()
    private var pendingNames = Set<String>()
    private(set) var created: [String] = []
    /// A directory of 10,000 names is about 2 MB of JSON. Leave room above the chunk cap.
    static let maxBytes = 32 * 1024 * 1024

    init(root: URL) {
        self.root = root
    }

    func put(_ data: Data) throws -> (hash: String, isNew: Bool) {
        // A record read() cannot decode must not be published. The version stays unwritten.
        let limit = min(Vault.directoryRecordLimit ?? Self.maxBytes, Self.maxBytes)
        if data.count > limit {
            throw ChronicleError.fail("A directory record is larger than Chronicle allows.")
        }
        let hash = Digest.sha256(data)
        if known.contains(hash) { return (hash, false) }
        let url = fileURL(hash)
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists && check(hash) == "ok" {
            known.insert(hash)
            return (hash, false)
        }
        try store(ChunkCodec.encode(data), at: url, hash: hash, track: !exists)
        known.insert(hash)
        return (hash, !exists)
    }

    func check(_ hash: String) -> String {
        let url = fileURL(hash)
        if !FileManager.default.fileExists(atPath: url.path) { return "missing" }
        if regularFileIsLargerThan(url, 16 + TreeStore.maxBytes) { return "damaged" }
        do {
            _ = try read(hash)
            return "ok"
        } catch {
            return "damaged"
        }
    }

    func read(_ hash: String) throws -> Data {
        guard Digest.isHash(hash) else { throw ChronicleError.fail("A directory id is not a SHA-256.") }
        let url = fileURL(hash)
        if regularFileIsLargerThan(url, 16 + TreeStore.maxBytes) {
            throw ChronicleError.fail("A directory record is larger than Chronicle allows.")
        }
        let raw = try Data(contentsOf: url)
        let data = try ChunkCodec.decode(raw, max: TreeStore.maxBytes)
        if Digest.sha256(data) != hash {
            throw ChronicleError.fail("Damaged directory record \(hash.prefix(12)).")
        }
        return data
    }

    func discardNew() {
        for hash in created {
            try? FileManager.default.removeItem(at: fileURL(hash))
        }
        created.removeAll()
    }

    func flushNames() throws {
        for path in pendingNames.sorted() {
            do {
                try Durable.sync(path)
            } catch {
                let detail = (error as? ChronicleError)?.message ?? error.localizedDescription
                throw ChronicleError.fail("Could not make the history durable (\(detail)).")
            }
        }
        pendingNames.removeAll()
    }

    private func store(_ encoded: Data, at url: URL, hash: String, track: Bool) throws {
        try installDurable(encoded, at: url, noun: "a directory", names: &pendingNames)
        if track { created.append(hash) }
    }

    private func fileURL(_ hash: String) -> URL {
        let shard = String(hash.prefix(2))
        return root.appendingPathComponent("trees").appendingPathComponent(shard).appendingPathComponent(hash)
    }
}

private final class VaultLock {
    private var fd: Int32

    init(url: URL) throws {
        let fd = url.path.withCString { open($0, O_CREAT | O_RDWR, 0o644) }
        if fd < 0 {
            throw ChronicleError.fail("Could not lock the history (\(String(cString: strerror(errno)))).")
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            throw ChronicleError.fail("Another snapshot is using this history.")
        }
        self.fd = fd
    }

    func release() {
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    deinit { release() }
}

enum Vault {
    /// Self-test only. The next snapshot throws once at this point.
    enum SnapshotFault {
        /// Throws after the manifest has been written to a temporary file, before it is published.
        case publishingManifest
        case writingHead
        /// Throws after the first file of a move has been copied, before the original is removed.
        case copyingHistory
        /// Removes one copied version before the check, so the copy can look intact and still disagree.
        case droppingCopiedVersion
    }

    static var fault: SnapshotFault?
    /// Self-test only. A directory record larger than this many bytes is refused. Nil uses the format limit.
    static var directoryRecordLimit: Int?

    /// A launch scan. `changed` means a watch snapshot would keep a version.
    /// `settled` is false when a version was published while the folder was being read.
    struct Probe: Equatable {
        var changed: Bool
        var settled: Bool
    }

    static func snapshot(
        source: URL,
        vault: URL,
        label: String,
        reason: String,
        verify: Bool,
        progress: ((String) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> Snapshot? {
        if !SnapshotPlace.isReachable(vault.path) {
            throw ChronicleError.fail("Snapshots are unavailable. Plug the drive back in.")
        }
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let lock = try VaultLock(url: vault.appendingPathComponent("lock"))
        defer { lock.release() }
        _ = try healUnlocked(vault)

        let sourceURL = URL(fileURLWithPath: source.resolvingSymlinksInPath().path, isDirectory: true)
        guard isDirectory(sourceURL.path) else {
            throw ChronicleError.fail("Choose a folder to watch.")
        }
        let config = try ensureConfig(vault: vault, source: sourceURL, name: sourceURL.lastPathComponent)
        try config.chunk.validate()

        let pending = vault.appendingPathComponent("pending")
        // Heal removes this marker only after a complete cleanup. A snapshot must not
        // clear it again, or the next open will not retry that cleanup.
        let keepPending = FileManager.default.fileExists(atPath: pending.path)
        try Data("1".utf8).write(to: pending, options: .atomic)
        let store = ChunkStore(root: vault)
        let trees = TreeStore(root: vault)
        var committed = false
        defer {
            if !committed {
                store.discardNew()
                trees.discardNew()
            }
            if !keepPending {
                try? FileManager.default.removeItem(at: pending)
            }
            fault = nil
            directoryRecordLimit = nil
        }

        let parent = try newestBody(vault)
        try stopIfCancelled(isCancelled)
        let walked = try collect(
            source: sourceURL,
            vault: vault,
            skip: Set(config.skipNames),
            progress: progress,
            isCancelled: isCancelled
        )
        let built = try buildContents(
            walked: walked,
            parent: parent,
            skip: Set(config.skipNames),
            verify: verify,
            policy: .store(store, config.chunk),
            progress: progress,
            isCancelled: isCancelled
        )

        try stopIfCancelled(isCancelled)
        guard Snapshot.shouldKeep(
            reason: reason,
            stats: built.stats,
            parent: parent,
            files: built.files,
            skipped: built.skipped,
            skip: Set(config.skipNames)
        ) else { return nil }

        try stopIfCancelled(isCancelled)
        let rootTree = try writeTrees(built.files, store: trees)
        try stopIfCancelled(isCancelled)
        var snap = Snapshot(
            format: AppInfo.format,
            id: SnapshotID.make(),
            parent: parent?.id,
            created: TimeText.nowISO(),
            label: label,
            reason: reason,
            source: sourceURL.path,
            files: built.files,
            skipped: built.skipped,
            stats: built.stats,
            tree: rootTree
        )
        let directory = vault.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Each new file is fsynced, then the directories that name it. One F_FULLFSYNC
        // of the version file flushes the drive cache. The rename after that is the commit.
        // The head is an index listHeads can rebuild.
        try store.flushNames()
        try trees.flushNames()
        try publishBody(snap, directory: directory)
        committed = true
        try syncDurable(directory)
        do {
            try checkFault(.writingHead)
            try JSONFile.write(snap.head, to: directory.appendingPathComponent(snap.id + ".head.json"), pretty: true)
        } catch {
            // The body is the version. listHeads rebuilds a missing head.
        }
        var updated = config
        updated.source = sourceURL.path
        try? JSONFile.write(updated, to: vault.appendingPathComponent("vault.json"), pretty: true)
        let thinned = (try? pruneUnlocked(vault, now: Date())) ?? .none
        snap.pruned = thinned.count
        snap.pruneDetail = thinned
        return snap
    }

    static func probe(source: URL, vault: URL) throws -> Probe {
        let sourceURL = URL(fileURLWithPath: source.resolvingSymlinksInPath().path, isDirectory: true)
        guard isDirectory(sourceURL.path) else {
            throw ChronicleError.fail("Choose a folder to watch.")
        }
        let baseline = try? listHeads(vault).first?.id
        let parent = try newestBody(vault)
        let skip = Set((try? config(vault).skipNames) ?? VaultConfig.defaultSkip)
        let walked = try collect(source: sourceURL, vault: vault, skip: skip, progress: nil, isCancelled: nil)
        let built = try buildContents(
            walked: walked,
            parent: parent,
            skip: skip,
            verify: false,
            policy: .probe,
            progress: nil,
            isCancelled: nil
        )
        let after = try? listHeads(vault).first?.id
        if after != baseline {
            return Probe(changed: false, settled: false)
        }
        return Probe(
            changed: Snapshot.shouldKeep(
                reason: "watch",
                stats: built.stats,
                parent: parent,
                files: built.files,
                skipped: built.skipped,
                skip: skip
            ),
            settled: true
        )
    }

    static func listHeads(_ vault: URL) throws -> [SnapshotHead] {
        let directory = vault.appendingPathComponent("snapshots")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var heads: [SnapshotHead] = []
        let seen = Set(names)
        for name in names where name.hasSuffix(".json") && !name.hasSuffix(".head.json") {
            let id = String(name.dropLast(".json".count))
            guard SnapshotID.valid(id) else { continue }
            let headURL = directory.appendingPathComponent(id + ".head.json")
            if seen.contains(headURL.lastPathComponent),
               let head = try? JSONFile.read(SnapshotHead.self, from: headURL),
               head.id == id {
                continue
            }
            // A missing or unreadable index is rebuilt from the version file.
            if let snap = try? load(vault, id) {
                try? JSONFile.write(snap.head, to: headURL, pretty: true)
                heads.append(snap.head)
            }
        }
        for name in names where name.hasSuffix(".head.json") && !name.contains(".partial") {
            let url = directory.appendingPathComponent(name)
            guard let head = try? JSONFile.read(SnapshotHead.self, from: url), SnapshotID.valid(head.id) else { continue }
            // A head is an index. The version file is the version.
            guard seen.contains(head.id + ".json") else { continue }
            heads.append(head)
        }
        heads.sort { lhs, rhs in
            if lhs.created == rhs.created { return lhs.id > rhs.id }
            return lhs.created > rhs.created
        }
        var unique: [SnapshotHead] = []
        var ids = Set<String>()
        for head in heads where ids.insert(head.id).inserted {
            unique.append(head)
        }
        return unique
    }

    static func latestDate(_ vault: URL) -> Date? {
        guard let iso = try? listHeads(vault).first?.created else { return nil }
        return TimeText.parse(iso)
    }

    static func load(_ vault: URL, _ id: String) throws -> Snapshot {
        guard SnapshotID.valid(id) else { throw ChronicleError.fail("Unknown version.") }
        let url = vault.appendingPathComponent("snapshots").appendingPathComponent(id + ".json")
        if !FileManager.default.fileExists(atPath: url.path) {
            throw ChronicleError.fail("That version is already gone.")
        }
        let stored = try JSONFile.read(StoredSnapshot.self, from: url)
        if stored.format != AppInfo.format || stored.id != id {
            throw ChronicleError.fail("Version \(id) does not belong to this history.")
        }
        var snap = stored.snapshot()
        // A rewritten body can carry its own file list. That list wins.
        // A published body names one directory record and leaves the list out.
        if snap.files.isEmpty, let tree = stored.tree, !tree.isEmpty {
            snap.files = try expandTree(vault, tree)
        }
        return snap
    }

    /// The version a comparison uses. The recorded parent wins when it still loads.
    /// Otherwise the newest version that still exists before this one. The first version
    /// compares with nothing. The comparison waits only when no earlier version loads.
    struct Comparison {
        var parent: Snapshot?
        var comparable: Bool
        var substituted: Bool
    }

    static func compared(vault: URL, to snap: Snapshot) -> Comparison {
        if snap.parent == nil {
            return Comparison(parent: nil, comparable: true, substituted: false)
        }
        if let parentID = snap.parent, let parent = try? load(vault, parentID) {
            return Comparison(parent: parent, comparable: true, substituted: false)
        }
        let older = ((try? snapshotIDs(vault)) ?? []).filter { $0 < snap.id }.sorted()
        for id in older.reversed() {
            if let parent = try? load(vault, id) {
                return Comparison(parent: parent, comparable: true, substituted: true)
            }
        }
        return Comparison(parent: nil, comparable: false, substituted: false)
    }

    /// New bytes for one version row. A parent file that is still there keeps the saved counts.
    /// A missing parent file is measured against the predecessor the comparison uses.
    static func glance(vault: URL, snap: Snapshot) -> VersionGlance {
        if let parent = snap.parent, !parentBodyExists(vault, parent) {
            let basis = compared(vault: vault, to: snap)
            return Diff.measure(snap: snap, parent: basis.parent, substituted: basis.substituted)
        }
        return storedGlance(snap.stats)
    }

    private static var rowCache: [String: VersionGlance] = [:]

    /// The version list. Rows whose parent file is present use the head. A missing parent
    /// is measured once and kept: a saved version does not change.
    static func rowGlances(vault: URL, heads: [SnapshotHead]) -> [String: VersionGlance] {
        let directory = vault.appendingPathComponent("snapshots")
        let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        let present = names.map(Set.init)
        let prefix = vault.path + "\n"
        var shown: [String: VersionGlance] = [:]
        shown.reserveCapacity(heads.count)
        for head in heads {
            let key = prefix + head.id
            if let cached = rowCache[key] {
                shown[head.id] = cached
                continue
            }
            let parentMissing = present.map { listed in
                head.parent.map { !listed.contains($0 + ".json") } ?? false
            } ?? false
            if parentMissing, let snap = try? load(vault, head.id) {
                let glance = self.glance(vault: vault, snap: snap)
                rowCache[key] = glance
                shown[head.id] = glance
            } else {
                shown[head.id] = storedGlance(head.stats)
            }
        }
        return shown
    }

    private static func parentBodyExists(_ vault: URL, _ parent: String) -> Bool {
        let url = vault.appendingPathComponent("snapshots").appendingPathComponent(parent + ".json")
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func storedGlance(_ stats: SnapshotStats) -> VersionGlance {
        let quiet = stats.newChunkBytes == 0 && stats.addedFiles == 0 && stats.changedFiles == 0 && stats.removedFiles == 0
        return VersionGlance(newBytes: stats.newChunkBytes, quiet: quiet)
    }

    static func totals(_ vault: URL) throws -> VaultTotals {
        let heads = try listHeads(vault)
        let chunkBytes = directoryBytes(vault.appendingPathComponent("chunks"))
        var manifestBytes = directoryBytes(vault.appendingPathComponent("snapshots"))
        manifestBytes += directoryBytes(vault.appendingPathComponent("trees"))
        for name in ["vault.json", "FORMAT"] {
            manifestBytes += fileBytes(vault.appendingPathComponent(name))
        }
        let raw = heads.reduce(Int64(0)) { $0 + $1.stats.logicalBytes }
        return VaultTotals(
            snapshotCount: heads.count,
            storedBytes: chunkBytes + manifestBytes,
            chunkBytes: chunkBytes,
            manifestBytes: manifestBytes,
            rawCopyBytes: raw,
            latestLogicalBytes: heads.first?.stats.logicalBytes ?? 0
        )
    }

    static func config(_ vault: URL) throws -> VaultConfig {
        try JSONFile.read(VaultConfig.self, from: vault.appendingPathComponent("vault.json"))
    }

    static func restore(vault: URL, snapshot id: String, dest: URL, allowInsideSource: Bool) throws {
        let snap = try load(vault, id)
        let destination = dest.standardizedFileURL
        try guardDestination(destination, source: snap.source, vault: vault, allowInsideSource: allowInsideSource)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let store = ChunkStore(root: vault)
        let directories = snap.files.filter { $0.kind == "dir" }.sorted { $0.path.count > $1.path.count }
        for entry in snap.files where entry.kind == "file" || entry.kind == "link" {
            let url = try destinationURL(destination, entry.path)
            try prepareDirectory(url.deletingLastPathComponent(), root: destination)
            if entry.kind == "link" {
                try writeLink(url, target: entry.target ?? "", name: entry.path)
            } else {
                try writeFile(url, entry: entry, store: store)
            }
            if entry.mtimeNS != 0 {
                applyMtime(url.path, entry.mtimeNS)
            }
        }
        for entry in directories {
            let url = try destinationURL(destination, entry.path)
            try prepareDirectory(url, root: destination)
            if entry.mode != 0 { chmod(url.path, mode_t(entry.mode)) }
            if entry.mtimeNS != 0 { applyMtime(url.path, entry.mtimeNS) }
        }
    }

    static func restoreFile(vault: URL, snapshot id: String, path: String, dest: URL, allowInsideSource: Bool) throws {
        let snap = try load(vault, id)
        guard let entry = snap.files.first(where: { $0.path == path }) else {
            throw ChronicleError.fail("That file is not in this version.")
        }
        if entry.kind == "dir" {
            throw ChronicleError.fail("Choose a file to restore.")
        }
        let destination = dest.standardizedFileURL
        try guardDestination(destination, source: snap.source, vault: vault, allowInsideSource: allowInsideSource)
        try prepareDirectory(destination.deletingLastPathComponent(), root: destination.deletingLastPathComponent())
        let store = ChunkStore(root: vault)
        if entry.kind == "link" {
            try writeLink(destination, target: entry.target ?? "", name: entry.path)
        } else {
            try writeFile(destination, entry: entry, store: store)
        }
        if entry.mtimeNS != 0 { applyMtime(destination.path, entry.mtimeNS) }
    }

    /// Writes one recorded folder and everything stored inside it. `dest` is that folder.
    /// Files already in `dest` stay until their own copy is complete. Other files there are left in place.
    static func restoreDirectory(vault: URL, snapshot id: String, path: String, dest: URL, allowInsideSource: Bool) throws {
        guard RelPath.isSafe(path) else {
            throw ChronicleError.fail("Refusing a path that leaves the folder.")
        }
        let snap = try load(vault, id)
        if let entry = snap.files.first(where: { $0.path == path }), entry.kind != "dir" {
            throw ChronicleError.fail("Choose a folder to restore.")
        }
        let inside = snap.files.filter { $0.path == path || $0.path.hasPrefix(path + "/") }
        guard inside.contains(where: { $0.path == path && $0.kind == "dir" }) else {
            throw ChronicleError.fail("That folder is not in this version.")
        }
        let destination = dest.standardizedFileURL
        try guardDestination(destination, source: snap.source, vault: vault, allowInsideSource: allowInsideSource)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let store = ChunkStore(root: vault)
        for entry in inside where entry.path != path && (entry.kind == "file" || entry.kind == "link") {
            let relative = String(entry.path.dropFirst(path.count + 1))
            let url = try destinationURL(destination, relative)
            try prepareDirectory(url.deletingLastPathComponent(), root: destination)
            if entry.kind == "link" {
                try writeLink(url, target: entry.target ?? "", name: entry.path)
            } else {
                try writeFile(url, entry: entry, store: store)
            }
            if entry.mtimeNS != 0 { applyMtime(url.path, entry.mtimeNS) }
        }
        let directories = inside.filter { $0.kind == "dir" }.sorted { $0.path.count > $1.path.count }
        for entry in directories {
            let relative = entry.path == path ? "" : String(entry.path.dropFirst(path.count + 1))
            let url = relative.isEmpty ? destination : try destinationURL(destination, relative)
            if !relative.isEmpty {
                try prepareDirectory(url, root: destination)
            }
            if entry.mode != 0 { chmod(url.path, mode_t(entry.mode)) }
            if entry.mtimeNS != 0 { applyMtime(url.path, entry.mtimeNS) }
        }
    }

    static func delete(vault: URL, id: String) throws -> Int64 {
        guard SnapshotID.valid(id) else { throw ChronicleError.fail("Unknown version.") }
        let lock = try VaultLock(url: vault.appendingPathComponent("lock"))
        defer { lock.release() }
        let directory = vault.appendingPathComponent("snapshots")
        let body = directory.appendingPathComponent(id + ".json")
        if !FileManager.default.fileExists(atPath: body.path) {
            throw ChronicleError.fail("That version is already gone.")
        }
        try FileManager.default.removeItem(at: body)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id + ".head.json"))
        do {
            let result = try collectGarbage(vault)
            guard result.complete else {
                throw ChronicleError.fail("That version was deleted. Unused chunks were left in place because another version could not be read.")
            }
            return result.freed
        } catch let error as ChronicleError where error.code == .versionListUnreadable {
            throw ChronicleError.fail("That version was deleted. Unused chunks were left in place because the version list could not be read.")
        }
    }

    static func verifyHistory(vault: URL, progress: ((String) -> Void)? = nil) throws -> HistoryCheck {
        let lock = try VaultLock(url: vault.appendingPathComponent("lock"))
        defer { lock.release() }
        let names = try snapshotDirectoryNames(vault)
        var users: [String: [String]] = [:]
        var problems: [HistoryCheck.Problem] = []
        var versionCount = 0
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasSuffix(".head.json") {
            let id = String(name.dropLast(".json".count))
            guard SnapshotID.valid(id) else { continue }
            versionCount += 1
            progress?(id)
            let stored: StoredSnapshot
            do {
                stored = try readStored(vault, id)
            } catch {
                problems.append(HistoryCheck.Problem(hash: id, kind: "manifest", versions: [id]))
                continue
            }
            var seen = Set<String>()
            let inline = stored.files ?? []
            if !inline.isEmpty {
                for file in inline {
                    for hash in file.chunks where Digest.isHash(hash) && seen.insert(hash).inserted {
                        users[hash, default: []].append(id)
                    }
                }
            }
            if let tree = stored.tree, !tree.isEmpty {
                let walked = walkTree(vault, tree)
                if inline.isEmpty {
                    for hash in walked.chunks where seen.insert(hash).inserted {
                        users[hash, default: []].append(id)
                    }
                }
                for problem in walked.problems {
                    if let index = problems.firstIndex(where: { $0.hash == problem.hash && $0.kind == problem.kind }) {
                        if !problems[index].versions.contains(id) {
                            problems[index].versions.append(id)
                        }
                    } else {
                        problems.append(HistoryCheck.Problem(hash: problem.hash, kind: problem.kind, versions: [id]))
                    }
                }
            }
        }
        let store = ChunkStore(root: vault)
        for hash in users.keys.sorted() {
            progress?(String(hash.prefix(12)))
            let kind = store.check(hash)
            if kind == "ok" { continue }
            if kind == "damaged" { store.quarantine(hash) }
            problems.append(HistoryCheck.Problem(hash: hash, kind: kind, versions: users[hash] ?? []))
        }
        return HistoryCheck(versionCount: versionCount, chunkCount: users.count, problems: problems)
    }

    @discardableResult
    static func heal(_ vault: URL) throws -> PruneResult {
        guard FileManager.default.fileExists(atPath: vault.path) else { return .none }
        let lock = try VaultLock(url: vault.appendingPathComponent("lock"))
        defer { lock.release() }
        return try healUnlocked(vault, pruneHistory: true)
    }

    static func clean(_ vault: URL) throws -> CleanResult {
        let lock = try VaultLock(url: vault.appendingPathComponent("lock"))
        defer { lock.release() }
        let thinned = (try? pruneUnlocked(vault, now: Date())) ?? .none
        let result = try collectGarbage(vault)
        guard result.complete else {
            throw ChronicleError.fail("A version could not be read, so unused chunks were left in place.")
        }
        try? FileManager.default.removeItem(at: vault.appendingPathComponent("pending"))
        return CleanResult(freed: thinned.freed + result.freed, thinning: thinned)
    }

    /// Copies a history onto another folder or drive and checks that copy.
    /// `commit` saves the new location. The original is removed only after that returns.
    static func relocate(from: URL, to: URL, commit: () throws -> Void = {}) throws {
        let source = from.resolvingSymlinksInPath().standardizedFileURL
        let dest = to.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ChronicleError.fail("Snapshots are unavailable. Plug the drive back in.")
        }
        if source.path == dest.path { return }
        if PathGuard.isInside(dest.path, of: source.path) || PathGuard.isInside(source.path, of: dest.path) {
            throw ChronicleError.fail("Choose a place outside the current snapshots.")
        }
        let lock = try VaultLock(url: source.appendingPathComponent("lock"))
        defer { lock.release() }
        let parent = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            let items = (try FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil))
                .filter { $0.lastPathComponent != ".DS_Store" }
            guard items.isEmpty else {
                throw ChronicleError.fail("That folder already has files in it.")
            }
            try FileManager.default.removeItem(at: dest)
        }
        let temp = parent.appendingPathComponent(".chronicle-moving-\(UUID().uuidString)", isDirectory: true)
        var published = false
        defer {
            if !published {
                try? FileManager.default.removeItem(at: temp)
            }
        }
        let hadFormat = FileManager.default.fileExists(atPath: source.appendingPathComponent("FORMAT").path)
        try copyVault(from: source, to: temp)
        if consumeFault(.droppingCopiedVersion) {
            try dropOneCopiedVersion(temp)
        }
        if hadFormat { try requireFormat(temp) }
        let report: HistoryCheck
        do {
            report = try verifyHistory(vault: temp)
        } catch {
            throw ChronicleError.fail("The copy is not intact. The original history was left where it is. \(error.localizedDescription)")
        }
        if !report.problems.isEmpty {
            throw ChronicleError.fail("The copy is not intact. The original history was left where it is. \(report.summary)")
        }
        let sourceIDs: Set<String>
        let copyIDs: Set<String>
        do {
            sourceIDs = try snapshotIDs(source)
            copyIDs = try snapshotIDs(temp)
        } catch {
            throw ChronicleError.fail("The copy is not intact. The original history was left where it is. \(error.localizedDescription)")
        }
        if sourceIDs != copyIDs {
            throw ChronicleError.fail("The copy does not have the same versions. The original history was left where it is.")
        }
        try FileManager.default.moveItem(at: temp, to: dest)
        published = true
        do {
            try commit()
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        do {
            try removeVault(source)
        } catch {
            throw ChronicleError.fail("Snapshots are in \(dest.path). The old copy is still on disk.")
        }
    }

    /// File by file, so a failure mid-copy can delete the partial folder and leave the original.
    private static func copyVault(from source: URL, to dest: URL) throws {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let root = source.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw ChronicleError.fail("The snapshots could not be copied.")
        }
        var copiedFile = false
        for case let item as URL in enumerator {
            let relative = try vaultRelative(item, root: root)
            if relative.isEmpty { continue }
            let target = dest.appendingPathComponent(relative)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true && values.isSymbolicLink != true {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: item, to: target)
            if !copiedFile {
                copiedFile = true
                try checkFault(.copyingHistory)
            }
        }
    }

    /// A path under `root`, using the path the enumerator returned or its resolved form.
    private static func vaultRelative(_ item: URL, root: String) throws -> String {
        let itemPath = item.standardizedFileURL.path
        if itemPath == root { return "" }
        if itemPath.hasPrefix(root + "/") {
            return String(itemPath.dropFirst(root.count + 1))
        }
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedItem = item.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(item.lastPathComponent).path
        if resolvedItem == resolvedRoot { return "" }
        if resolvedItem.hasPrefix(resolvedRoot + "/") {
            return String(resolvedItem.dropFirst(resolvedRoot.count + 1))
        }
        throw ChronicleError.fail("The snapshots could not be copied.")
    }

    /// Names in `snapshots/`. A missing directory has no versions. A read error is not an empty list.
    private static func snapshotDirectoryNames(_ vault: URL) throws -> [String] {
        let directory = vault.appendingPathComponent("snapshots")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            throw ChronicleError.versionListUnreadable
        }
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw ChronicleError.versionListUnreadable
        }
    }

    private static func snapshotIDs(_ vault: URL) throws -> Set<String> {
        var ids = Set<String>()
        for name in try snapshotDirectoryNames(vault) where name.hasSuffix(".json") && !name.hasSuffix(".head.json") {
            let id = String(name.dropLast(".json".count))
            guard SnapshotID.valid(id) else { continue }
            ids.insert(id)
        }
        return ids
    }

    private static func dropOneCopiedVersion(_ vault: URL) throws {
        let directory = vault.appendingPathComponent("snapshots")
        let names = try snapshotDirectoryNames(vault)
        guard let name = names.first(where: { name in
            guard name.hasSuffix(".json"), !name.hasSuffix(".head.json") else { return false }
            return SnapshotID.valid(String(name.dropLast(".json".count)))
        }) else {
            throw ChronicleError.fail("Simulated failure.")
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    private static func consumeFault(_ point: SnapshotFault) -> Bool {
        guard fault == point else { return false }
        fault = nil
        return true
    }

    private static func requireFormat(_ vault: URL) throws {
        let text = (try? String(contentsOf: vault.appendingPathComponent("FORMAT"), encoding: .utf8)) ?? ""
        guard text.trimmingCharacters(in: .whitespacesAndNewlines) == AppInfo.format else {
            throw ChronicleError.fail("The snapshots did not arrive intact.")
        }
    }

    static func removeVault(_ vault: URL) throws {
        let format = vault.appendingPathComponent("FORMAT")
        let text = (try? String(contentsOf: format, encoding: .utf8)) ?? ""
        guard text.trimmingCharacters(in: .whitespacesAndNewlines) == AppInfo.format else {
            throw ChronicleError.fail("Refusing to delete a folder that is not a Chronicle history.")
        }
        try FileManager.default.removeItem(at: vault)
    }

    /// Freed bytes, and whether every version file was read.
    /// An incomplete scan must not delete a chunk: the unreadable version may name it.
    private struct GarbageResult {
        var freed: Int64
        var complete: Bool
    }

    private static func healUnlocked(_ vault: URL, pruneHistory: Bool = false) throws -> PruneResult {
        let names: [String]
        do {
            names = try snapshotDirectoryNames(vault)
        } catch {
            // An unreadable version list is not an empty one. Leave every chunk.
            return .none
        }
        let directory = vault.appendingPathComponent("snapshots")
        for name in names where name.hasSuffix(".partial") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        for name in names where name.hasSuffix(".head.json") && !name.contains(".partial") {
            let id = String(name.dropLast(".head.json".count))
            guard SnapshotID.valid(id), !names.contains(id + ".json") else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        let pending = vault.appendingPathComponent("pending")
        if FileManager.default.fileExists(atPath: pending.path) {
            let result = try collectGarbage(vault)
            if result.complete {
                try? FileManager.default.removeItem(at: pending)
            }
        }
        if pruneHistory {
            return (try? pruneUnlocked(vault, now: Date())) ?? .none
        }
        return .none
    }

    private static func collectGarbage(_ vault: URL) throws -> GarbageResult {
        let names = try snapshotDirectoryNames(vault)
        var liveChunks = Set<String>()
        var liveTrees = Set<String>()
        var complete = true
        for name in names where name.hasSuffix(".json") && !name.hasSuffix(".head.json") {
            let id = String(name.dropLast(".json".count))
            guard SnapshotID.valid(id) else { continue }
            do {
                let stored = try readStored(vault, id)
                let inline = stored.files ?? []
                if !inline.isEmpty {
                    for file in inline {
                        for hash in file.chunks where Digest.isHash(hash) {
                            liveChunks.insert(hash)
                        }
                    }
                }
                if let tree = stored.tree, !tree.isEmpty {
                    let walked = walkTree(vault, tree)
                    if !walked.problems.isEmpty { complete = false }
                    liveTrees.formUnion(walked.trees)
                    // Opening a version with an empty file list uses the directory record.
                    if inline.isEmpty {
                        liveChunks.formUnion(walked.chunks)
                    }
                }
            } catch {
                complete = false
            }
        }
        let freed = reclaim(vault.appendingPathComponent("chunks"), live: liveChunks, complete: complete)
            + reclaim(vault.appendingPathComponent("trees"), live: liveTrees, complete: complete)
        return GarbageResult(freed: freed, complete: complete)
    }

    /// Deletes partial names always. Deletes an unreferenced hash only when every version was read.
    private static func reclaim(_ root: URL, live: Set<String>, complete: Bool) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else {
            return 0
        }
        var freed: Int64 = 0
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let unreferenced = complete && Digest.isHash(name) && !live.contains(name)
            // A .damaged sibling goes once the good file is back, even if this pass
            // already removed that file because nothing names it anymore.
            let retired = damagedStem(name).map { hash -> Bool in
                guard Digest.isHash(hash) else { return false }
                let sibling = url.deletingLastPathComponent().appendingPathComponent(hash)
                if FileManager.default.fileExists(atPath: sibling.path) { return true }
                return complete && !live.contains(hash)
            } ?? false
            if name.hasSuffix(".partial") || unreferenced || retired {
                let size = Int64(values?.fileSize ?? 0)
                try? FileManager.default.removeItem(at: url)
                freed += size
            }
        }
        return freed
    }

    /// `<hash>.damaged` keeps the bad bytes until a good copy of that chunk is stored again.
    private static func damagedStem(_ name: String) -> String? {
        let suffix = ".damaged"
        guard name.hasSuffix(suffix) else { return nil }
        return String(name.dropLast(suffix.count))
    }

    private enum ReadPolicy {
        case store(ChunkStore, ChunkParams)
        case probe
    }

    private static func checkFault(_ point: SnapshotFault) throws {
        guard fault == point else { return }
        fault = nil
        throw ChronicleError.fail("Simulated failure.")
    }

    /// One name inside a directory record. The hash is of this JSON, so an unchanged directory is stored once.
    private struct TreeNode: Codable {
        var name: String
        var kind: String
        var mode: UInt32
        var mtimeNS: Int64
        var size: Int64?
        var chunks: [String]?
        var lengths: [Int]?
        var target: String?
        var tree: String?

        enum CodingKeys: String, CodingKey {
            case name, kind, mode, mtimeNS, size, chunks, lengths, target, tree
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(kind, forKey: .kind)
            try container.encode(mode, forKey: .mode)
            try container.encode(mtimeNS, forKey: .mtimeNS)
            try container.encodeIfPresent(size, forKey: .size)
            try container.encodeIfPresent(chunks, forKey: .chunks)
            try container.encodeIfPresent(lengths, forKey: .lengths)
            try container.encodeIfPresent(target, forKey: .target)
            try container.encodeIfPresent(tree, forKey: .tree)
        }

        init(name: String, kind: String, mode: UInt32, mtimeNS: Int64, size: Int64?, chunks: [String]?, lengths: [Int]?, target: String?, tree: String?) {
            self.name = name
            self.kind = kind
            self.mode = mode
            self.mtimeNS = mtimeNS
            self.size = size
            self.chunks = chunks
            self.lengths = lengths
            self.target = target
            self.tree = tree
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            kind = try container.decode(String.self, forKey: .kind)
            mode = try container.decode(UInt32.self, forKey: .mode)
            mtimeNS = try container.decode(Int64.self, forKey: .mtimeNS)
            size = try container.decodeIfPresent(Int64.self, forKey: .size)
            chunks = try container.decodeIfPresent([String].self, forKey: .chunks)
            lengths = try container.decodeIfPresent([Int].self, forKey: .lengths)
            target = try container.decodeIfPresent(String.self, forKey: .target)
            tree = try container.decodeIfPresent(String.self, forKey: .tree)
        }
    }

    /// The version file. `files` is omitted when `tree` holds the directory records.
    private struct StoredSnapshot: Codable {
        var format: String
        var id: String
        var parent: String?
        var created: String
        var label: String
        var reason: String
        var source: String
        var files: [Entry]?
        var tree: String?
        var skipped: [String]
        var stats: SnapshotStats

        enum CodingKeys: String, CodingKey {
            case format, id, parent, created, label, reason, source, files, tree, skipped, stats
        }

        init(_ snap: Snapshot, inlineFiles: Bool) {
            format = snap.format
            id = snap.id
            parent = snap.parent
            created = snap.created
            label = snap.label
            reason = snap.reason
            source = snap.source
            files = inlineFiles ? snap.files : nil
            tree = snap.tree
            skipped = snap.skipped
            stats = snap.stats
        }

        func snapshot() -> Snapshot {
            Snapshot(
                format: format,
                id: id,
                parent: parent,
                created: created,
                label: label,
                reason: reason,
                source: source,
                files: files ?? [],
                skipped: skipped,
                stats: stats,
                tree: tree
            )
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            format = try container.decode(String.self, forKey: .format)
            id = try container.decode(String.self, forKey: .id)
            parent = try container.decodeIfPresent(String.self, forKey: .parent)
            created = try container.decode(String.self, forKey: .created)
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
            reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
            source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
            files = try container.decodeIfPresent([Entry].self, forKey: .files)
            tree = try container.decodeIfPresent(String.self, forKey: .tree)
            skipped = try container.decodeIfPresent([String].self, forKey: .skipped) ?? []
            stats = try container.decodeIfPresent(SnapshotStats.self, forKey: .stats) ?? SnapshotStats()
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(format, forKey: .format)
            try container.encode(id, forKey: .id)
            try container.encode(parent, forKey: .parent)
            try container.encode(created, forKey: .created)
            try container.encode(label, forKey: .label)
            try container.encode(reason, forKey: .reason)
            try container.encode(source, forKey: .source)
            try container.encodeIfPresent(files, forKey: .files)
            try container.encodeIfPresent(tree, forKey: .tree)
            try container.encode(skipped, forKey: .skipped)
            try container.encode(stats, forKey: .stats)
        }
    }

    private struct TreeWalk {
        var chunks = Set<String>()
        var trees = Set<String>()
        var problems: [(hash: String, kind: String)] = []
    }

    /// Last 24 hours: every version. The next 30 days: the oldest version in each UTC hour.
    /// Older than that: the oldest version of each UTC day. The newest version always stays.
    /// A label, a manual snapshot, or a version file that cannot be read stays as well,
    /// and does not take that hour or day slot.
    enum Retention {
        struct Pin: Equatable {
            var id: String
            var label: String = ""
            var reason: String = ""
            var protect: Bool = false
            var created: Date? = nil

            var pinned: Bool {
                if protect || reason == "manual" { return true }
                return !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }

        static func keep(_ ids: [String], now: Date) -> Set<String> {
            keep(ids.map { Pin(id: $0) }, now: now)
        }

        static func keep(_ pins: [Pin], now: Date) -> Set<String> {
            let day: TimeInterval = 24 * 60 * 60
            let month = 30 * day
            var kept = Set<String>()
            var dated: [(pin: Pin, date: Date)] = []
            for pin in pins {
                guard let date = date(from: pin.id) else {
                    kept.insert(pin.id)
                    continue
                }
                dated.append((pin, date))
            }
            dated.sort { lhs, rhs in
                if lhs.date == rhs.date { return lhs.pin.id < rhs.pin.id }
                return lhs.date < rhs.date
            }
            var seenHour = Set<String>()
            var seenDay = Set<String>()
            let newest = dated.last?.pin.id
            for item in dated {
                if item.pin.pinned {
                    kept.insert(item.pin.id)
                    continue
                }
                let age = now.timeIntervalSince(item.date)
                if item.pin.id == newest || age < day {
                    kept.insert(item.pin.id)
                    continue
                }
                if age < month {
                    let hour = String(item.pin.id.prefix(11))
                    if seenHour.insert(hour).inserted { kept.insert(item.pin.id) }
                } else {
                    let dayKey = String(item.pin.id.prefix(8))
                    if seenDay.insert(dayKey).inserted { kept.insert(item.pin.id) }
                }
            }
            return kept
        }

        static func date(from id: String) -> Date? {
            guard SnapshotID.valid(id) else { return nil }
            let chars = Array(id.prefix(15))
            func number(_ range: Range<Int>) -> Int? {
                Int(String(chars[range]))
            }
            guard chars.count == 15,
                  let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
                  let hour = number(9..<11), let minute = number(11..<13), let second = number(13..<15),
                  (1...12).contains(month), (1...31).contains(day),
                  (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
                return nil
            }
            var parts = DateComponents()
            parts.calendar = Calendar(identifier: .gregorian)
            parts.timeZone = TimeZone(secondsFromGMT: 0)
            parts.year = year
            parts.month = month
            parts.day = day
            parts.hour = hour
            parts.minute = minute
            parts.second = second
            return parts.date
        }
    }

    /// Drops versions outside the retention ladder and then frees records no remaining version names.
    static func prune(vault: URL, now: Date = Date()) throws -> PruneResult {
        let lock = try VaultLock(url: vault.appendingPathComponent("lock"))
        defer { lock.release() }
        return try pruneUnlocked(vault, now: now)
    }

    private static func pruneUnlocked(_ vault: URL, now: Date) throws -> PruneResult {
        let ids = try snapshotIDs(vault)
        var pins: [Retention.Pin] = []
        pins.reserveCapacity(ids.count)
        for id in ids {
            pins.append(pinFromHead(vault, id))
        }
        let kept = Retention.keep(pins, now: now)
        let directory = vault.appendingPathComponent("snapshots")
        var removed: [PrunedVersion] = []
        for pin in pins where !kept.contains(pin.id) {
            let body = directory.appendingPathComponent(pin.id + ".json")
            if FileManager.default.fileExists(atPath: body.path) {
                try FileManager.default.removeItem(at: body)
                removed.append(PrunedVersion(id: pin.id, created: pin.created))
            }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(pin.id + ".head.json"))
        }
        removed.sort { lhs, rhs in
            switch (lhs.created, rhs.created) {
            case let (left?, right?):
                if left == right { return lhs.id < rhs.id }
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.id < rhs.id
            }
        }
        guard !removed.isEmpty else { return .none }
        let result: PruneResult
        if let garbage = try? collectGarbage(vault) {
            result = PruneResult(removed: removed, freed: garbage.freed, complete: garbage.complete)
        } else {
            result = PruneResult(removed: removed, freed: 0, complete: false)
        }
        recordThinning(vault, result, at: now)
        return result
    }

    /// The log for one watched folder. A missing file has not started. An unreadable file is left as it is.
    static func thinningHistory(_ vault: URL) -> ThinningHistory {
        let url = vault.appendingPathComponent("thinning.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .ready }
        guard let log = try? JSONFile.read(ThinningLog.self, from: url) else {
            return ThinningHistory(log: .empty, readable: false)
        }
        return ThinningHistory(log: log, readable: true)
    }

    /// A log that will not parse is left in place, so a bad read does not start the total over.
    private static func recordThinning(_ vault: URL, _ result: PruneResult, at now: Date) {
        guard result.count > 0 else { return }
        let url = vault.appendingPathComponent("thinning.json")
        let current: ThinningLog
        if FileManager.default.fileExists(atPath: url.path) {
            guard let loaded = try? JSONFile.read(ThinningLog.self, from: url) else { return }
            current = loaded
        } else {
            current = .empty
        }
        try? JSONFile.write(current.recording(result, at: now), to: url, pretty: true)
    }

    /// Label and reason live in the head. The version body is not opened.
    /// A head that cannot be read stays, so a label is not lost with it.
    private static func pinFromHead(_ vault: URL, _ id: String) -> Retention.Pin {
        let url = vault.appendingPathComponent("snapshots").appendingPathComponent(id + ".head.json")
        guard let head = try? JSONFile.read(SnapshotHead.self, from: url), head.id == id else {
            return Retention.Pin(id: id, protect: true, created: Retention.date(from: id))
        }
        let created = TimeText.parse(head.created) ?? Retention.date(from: id)
        return Retention.Pin(id: id, label: head.label, reason: head.reason, created: created)
    }

    private static func readStored(_ vault: URL, _ id: String) throws -> StoredSnapshot {
        guard SnapshotID.valid(id) else { throw ChronicleError.fail("Unknown version.") }
        let url = vault.appendingPathComponent("snapshots").appendingPathComponent(id + ".json")
        if !FileManager.default.fileExists(atPath: url.path) {
            throw ChronicleError.fail("That version is already gone.")
        }
        let stored = try JSONFile.read(StoredSnapshot.self, from: url)
        if stored.format != AppInfo.format || stored.id != id {
            throw ChronicleError.fail("Version \(id) does not belong to this history.")
        }
        return stored
    }

    private static func parentPath(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    private static func leafName(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// Builds directory records from the leaves up. Identical contents keep one hash.
    private static func writeTrees(_ files: [Entry], store: TreeStore) throws -> String {
        var byParent: [String: [Entry]] = [:]
        var knownDirs = Set(files.filter { $0.kind == "dir" }.map(\.path))
        knownDirs.insert("")
        for entry in files {
            var parent = parentPath(entry.path)
            while !parent.isEmpty && !knownDirs.contains(parent) {
                let synthetic = Entry(
                    path: parent, kind: "dir", mode: 0o755, mtimeNS: 0,
                    size: 0, chunks: [], lengths: [], target: nil
                )
                byParent[parentPath(parent), default: []].append(synthetic)
                knownDirs.insert(parent)
                parent = parentPath(parent)
            }
        }
        for entry in files {
            byParent[parentPath(entry.path), default: []].append(entry)
        }
        func build(_ directory: String) throws -> String {
            var seen = Set<String>()
            var nodes: [TreeNode] = []
            let kids = (byParent[directory] ?? []).sorted { leafName($0.path) < leafName($1.path) }
            for entry in kids {
                let name = leafName(entry.path)
                if name.isEmpty || !seen.insert(name).inserted { continue }
                if entry.kind == "dir" {
                    let child = try build(entry.path)
                    nodes.append(TreeNode(
                        name: name, kind: "dir", mode: entry.mode, mtimeNS: entry.mtimeNS,
                        size: nil, chunks: nil, lengths: nil, target: nil, tree: child
                    ))
                } else if entry.kind == "link" {
                    nodes.append(TreeNode(
                        name: name, kind: "link", mode: entry.mode, mtimeNS: entry.mtimeNS,
                        size: entry.size, chunks: nil, lengths: nil, target: entry.target ?? "", tree: nil
                    ))
                } else {
                    nodes.append(TreeNode(
                        name: name, kind: "file", mode: entry.mode, mtimeNS: entry.mtimeNS,
                        size: entry.size, chunks: entry.chunks, lengths: entry.lengths, target: nil, tree: nil
                    ))
                }
            }
            let data = try JSONFile.encoder(pretty: false).encode(nodes)
            return try store.put(data).hash
        }
        return try build("")
    }

    private static func expandTree(_ vault: URL, _ root: String) throws -> [Entry] {
        let walked = walkTree(vault, root)
        if let problem = walked.problems.first {
            let word = problem.kind.hasPrefix("missing") ? "missing" : "damaged"
            throw ChronicleError.fail("A directory record is \(word).")
        }
        var files: [Entry] = []
        var stack: [(hash: String, prefix: String, chain: Set<String>)] = [(root, "", [])]
        while let next = stack.popLast() {
            if next.chain.contains(next.hash) {
                throw ChronicleError.fail("A directory record repeats itself.")
            }
            var chain = next.chain
            chain.insert(next.hash)
            let nodes: [TreeNode]
            do {
                let data = try TreeStore(root: vault).read(next.hash)
                nodes = try JSONDecoder().decode([TreeNode].self, from: data)
            } catch {
                throw ChronicleError.fail("A directory record is missing.")
            }
            for node in nodes {
                let path = next.prefix.isEmpty ? node.name : next.prefix + "/" + node.name
                guard RelPath.isSafe(path) else {
                    throw ChronicleError.fail("Refusing a path that leaves the folder.")
                }
                if node.kind == "dir" {
                    files.append(Entry(
                        path: path, kind: "dir", mode: node.mode, mtimeNS: node.mtimeNS,
                        size: 0, chunks: [], lengths: [], target: nil
                    ))
                    if let child = node.tree {
                        stack.append((child, path, chain))
                    }
                } else if node.kind == "link" {
                    files.append(Entry(
                        path: path, kind: "link", mode: node.mode, mtimeNS: node.mtimeNS,
                        size: node.size ?? 0, chunks: [], lengths: [], target: node.target ?? ""
                    ))
                } else {
                    files.append(Entry(
                        path: path, kind: "file", mode: node.mode, mtimeNS: node.mtimeNS,
                        size: node.size ?? 0, chunks: node.chunks ?? [], lengths: node.lengths ?? [], target: nil
                    ))
                }
            }
        }
        files.sort { $0.path < $1.path }
        return files
    }

    /// Reads a directory record and every record under it. A broken record is reported, not thrown.
    private static func walkTree(_ vault: URL, _ root: String) -> TreeWalk {
        var walk = TreeWalk()
        let store = TreeStore(root: vault)
        var pending = [root]
        while let hash = pending.popLast() {
            if !Digest.isHash(hash) {
                walk.problems.append((hash, "missing-directory"))
                continue
            }
            if !walk.trees.insert(hash).inserted { continue }
            let nodes: [TreeNode]
            do {
                let data = try store.read(hash)
                nodes = try JSONDecoder().decode([TreeNode].self, from: data)
            } catch {
                let kind = store.check(hash) == "missing" ? "missing-directory" : "damaged-directory"
                walk.problems.append((hash, kind))
                continue
            }
            for node in nodes {
                if node.kind == "dir" {
                    if let child = node.tree {
                        pending.append(child)
                    } else {
                        walk.problems.append((hash, "damaged-directory"))
                    }
                } else if node.kind != "link" {
                    for chunk in node.chunks ?? [] where Digest.isHash(chunk) {
                        walk.chunks.insert(chunk)
                    }
                }
            }
        }
        return walk
    }

    /// Writes the body beside the version list, then renames it into place.
    /// A crash or a thrown error before the rename leaves no version.
    private static func publishBody(_ snap: Snapshot, directory: URL) throws {
        let partial = directory.appendingPathComponent(snap.id + ".json.partial")
        let final = directory.appendingPathComponent(snap.id + ".json")
        if FileManager.default.fileExists(atPath: partial.path) {
            try? FileManager.default.removeItem(at: partial)
        }
        let data = try JSONFile.encoder(pretty: false).encode(StoredSnapshot(snap, inlineFiles: false))
        do {
            try data.write(to: partial, options: .atomic)
            do {
                try Durable.sync(partial.path)
                try Durable.force(partial.path)
            } catch {
                let detail = (error as? ChronicleError)?.message ?? error.localizedDescription
                throw ChronicleError.fail("Could not publish the version (\(detail)).")
            }
            try checkFault(.publishingManifest)
            try FileManager.default.moveItem(at: partial, to: final)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    private static func syncDurable(_ url: URL) throws {
        do {
            try Durable.sync(url.path)
        } catch {
            let detail = (error as? ChronicleError)?.message ?? error.localizedDescription
            throw ChronicleError.fail("Could not make the history durable (\(detail)).")
        }
    }

    /// True when the file can be opened. Permission and I/O failures count as unreadable.
    private static func canRead(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY)
        if fd < 0 { return false }
        close(fd)
        return true
    }

    /// Keeps the previous copy when one exists. A path with no copy is left for the unread count.
    private static func noteUnreadable(
        _ item: WalkItem,
        parentMap: [String: Entry],
        files: inout [Entry],
        skipped: inout [String],
        stats: inout SnapshotStats
    ) {
        skipped.append(item.relative)
        guard let old = parentMap[item.relative], old.kind == "file" || old.kind == "link" else { return }
        files.append(old)
        if old.kind == "file" {
            stats.fileCount += 1
            stats.logicalBytes += old.size
            stats.reusedChunkBytes += old.size
        } else {
            stats.linkCount += 1
        }
        stats.carriedFiles += 1
    }

    private static func buildContents(
        walked: (items: [WalkItem], skipped: [String]),
        parent: Snapshot?,
        skip: Set<String>,
        verify: Bool,
        policy: ReadPolicy,
        progress: ((String) -> Void)?,
        isCancelled: (() -> Bool)?
    ) throws -> (files: [Entry], skipped: [String], stats: SnapshotStats) {
        let parentMap = entriesByPath(parent?.files ?? [])
        var files: [Entry] = []
        var skipped = walked.skipped
        var stats = SnapshotStats()
        let accum = ChunkAccum()

        for item in walked.items {
            try stopIfCancelled(isCancelled)
            progress?(item.relative)
            switch item.kind {
            case "dir":
                let entry = Entry(
                    path: item.relative,
                    kind: "dir",
                    mode: item.mode,
                    mtimeNS: item.mtimeNS,
                    size: 0,
                    chunks: [],
                    lengths: [],
                    target: nil
                )
                files.append(entry)
                stats.dirCount += 1
                classify(entry, parent: parentMap[item.relative], stats: &stats, newBytes: 0, reusedBytes: 0)
            case "link":
                let entry = Entry(
                    path: item.relative,
                    kind: "link",
                    mode: item.mode,
                    mtimeNS: item.mtimeNS,
                    size: item.size,
                    chunks: [],
                    lengths: [],
                    target: item.linkTarget ?? ""
                )
                files.append(entry)
                stats.linkCount += 1
                classify(entry, parent: parentMap[item.relative], stats: &stats, newBytes: 0, reusedBytes: 0)
            case "file":
                if !verify,
                   let old = parentMap[item.relative],
                   old.kind == "file",
                   old.size == item.size,
                   old.mtimeNS == item.mtimeNS {
                    var kept = old
                    kept.mode = item.mode
                    files.append(kept)
                    stats.fileCount += 1
                    stats.logicalBytes += item.size
                    stats.reusedChunkBytes += item.size
                    if old.mode != item.mode {
                        stats.changedFiles += 1
                    } else {
                        stats.unchangedFiles += 1
                    }
                    continue
                }
                // A file that cannot be opened is carried or unread, not added.
                // The probe has to agree, or a folder Chronicle cannot read stays due forever.
                if !canRead(item.absolute) {
                    noteUnreadable(item, parentMap: parentMap, files: &files, skipped: &skipped, stats: &stats)
                    continue
                }
                if case .probe = policy {
                    files.append(Entry(
                        path: item.relative,
                        kind: "file",
                        mode: item.mode,
                        mtimeNS: item.mtimeNS,
                        size: item.size,
                        chunks: [],
                        lengths: [],
                        target: nil
                    ))
                    stats.fileCount += 1
                    stats.logicalBytes += item.size
                    if parentMap[item.relative] == nil {
                        stats.addedFiles += 1
                    } else {
                        stats.changedFiles += 1
                    }
                    continue
                }
                guard case .store(let store, let params) = policy else { continue }
                accum.reset()
                do {
                    try ingest(item.absolute, params: params, store: store, accum: accum, isCancelled: isCancelled)
                } catch let error as ChronicleError {
                    // The vault could not store the chunk. Saving the file as unreadable
                    // would publish a version that does not have these bytes.
                    throw error
                } catch {
                    noteUnreadable(item, parentMap: parentMap, files: &files, skipped: &skipped, stats: &stats)
                    continue
                }
                let readSize = accum.lengths.reduce(0, +)
                var mtime = item.mtimeNS
                let size = Int64(readSize)
                if let after = lstatInfo(item.absolute), after.kind == "file" {
                    if after.size != Int64(readSize) || after.mtimeNS != item.mtimeNS {
                        mtime = 0
                    }
                }
                let entry = Entry(
                    path: item.relative,
                    kind: "file",
                    mode: item.mode,
                    mtimeNS: mtime,
                    size: size,
                    chunks: accum.chunks,
                    lengths: accum.lengths,
                    target: nil
                )
                files.append(entry)
                stats.fileCount += 1
                stats.logicalBytes += size
                stats.newChunkBytes += accum.newBytes
                stats.reusedChunkBytes += accum.reusedBytes
                classify(entry, parent: parentMap[item.relative], stats: &stats, newBytes: accum.newBytes, reusedBytes: accum.reusedBytes)
                try stopIfCancelled(isCancelled)
            default:
                skipped.append(item.relative)
            }
        }

        var seen = Set(files.map(\.path))
        let trouble = skipped.filter { !RelPath.isExcluded($0, names: skip) }
        if let parent {
            for old in parent.files where !seen.contains(old.path) && trouble.contains(where: { old.path == $0 || old.path.hasPrefix($0 + "/") }) {
                files.append(old)
                seen.insert(old.path)
                switch old.kind {
                case "file":
                    stats.fileCount += 1
                    stats.logicalBytes += old.size
                    stats.reusedChunkBytes += old.size
                    stats.carriedFiles += 1
                case "link":
                    stats.linkCount += 1
                    stats.carriedFiles += 1
                case "dir":
                    stats.dirCount += 1
                default:
                    break
                }
            }
        }
        for path in trouble {
            if seen.contains(path) { continue }
            if files.contains(where: { $0.path == path || $0.path.hasPrefix(path + "/") }) { continue }
            stats.unreadFiles += 1
        }
        var removedPaths = Set<String>()
        for old in parent?.files ?? [] where !seen.contains(old.path) && (old.kind == "file" || old.kind == "link" || old.kind == "dir") {
            if removedPaths.insert(old.path).inserted {
                stats.removedFiles += 1
            }
        }
        stats.skippedCount = skipped.count
        var warnings = skipped.filter { !RelPath.isExcluded($0, names: skip) }
        let routine = skipped.filter { RelPath.isExcluded($0, names: skip) }
        warnings.append(contentsOf: routine)
        skipped = warnings.count > 200 ? Array(warnings.prefix(200)) : warnings
        files.sort { $0.path < $1.path }
        return (files, skipped, stats)
    }

    /// The newest version whose file still loads. A damaged newest file must not block the next snapshot.
    private static func newestBody(_ vault: URL) throws -> Snapshot? {
        for head in try listHeads(vault) {
            if let snap = try? load(vault, head.id) {
                return snap
            }
        }
        return nil
    }

    /// The first entry for a path wins. A repeated path in a damaged manifest must not crash the process.
    private static func entriesByPath(_ entries: [Entry]) -> [String: Entry] {
        var map: [String: Entry] = [:]
        map.reserveCapacity(entries.count)
        for entry in entries where map[entry.path] == nil {
            map[entry.path] = entry
        }
        return map
    }

    private static func ensureConfig(vault: URL, source: URL, name: String) throws -> VaultConfig {
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("chunks"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("snapshots"), withIntermediateDirectories: true)
        let configURL = vault.appendingPathComponent("vault.json")
        if FileManager.default.fileExists(atPath: configURL.path) {
            let config = try JSONFile.read(VaultConfig.self, from: configURL)
            guard config.format == AppInfo.format else {
                throw ChronicleError.fail("This history is \(config.format). Chronicle reads \(AppInfo.format).")
            }
            return config
        }
        let config = VaultConfig(
            format: AppInfo.format,
            id: UUID().uuidString,
            name: name,
            source: source.path,
            created: TimeText.nowISO(),
            chunk: .standard,
            skipNames: VaultConfig.defaultSkip
        )
        try AppInfo.format.appending("\n").write(to: vault.appendingPathComponent("FORMAT"), atomically: true, encoding: .utf8)
        try JSONFile.write(config, to: configURL, pretty: true)
        return config
    }

    private static func classify(_ entry: Entry, parent: Entry?, stats: inout SnapshotStats, newBytes: Int64, reusedBytes: Int64) {
        guard let parent else {
            stats.addedFiles += 1
            return
        }
        if parent.kind != entry.kind || parent.chunks != entry.chunks || parent.target != entry.target || parent.size != entry.size || parent.mode != entry.mode {
            stats.changedFiles += 1
        } else {
            stats.unchangedFiles += 1
        }
        _ = newBytes
        _ = reusedBytes
    }

    private static func ingest(
        _ path: String,
        params: ChunkParams,
        store: ChunkStore,
        accum: ChunkAccum,
        isCancelled: (() -> Bool)?
    ) throws {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let splitter = ChunkSplitter(params: params)
        splitter.onChunk = { data in
            try stopIfCancelled(isCancelled)
            let (hash, isNew) = try store.put(data)
            accum.chunks.append(hash)
            accum.lengths.append(data.count)
            if isNew { accum.newBytes += Int64(data.count) }
            else { accum.reusedBytes += Int64(data.count) }
        }
        while true {
            try stopIfCancelled(isCancelled)
            let piece = try handle.read(upToCount: 256 * 1024) ?? Data()
            if piece.isEmpty { break }
            try splitter.feed(piece)
        }
        try splitter.finish()
    }

    private static func stopIfCancelled(_ isCancelled: (() -> Bool)?) throws {
        if isCancelled?() == true {
            throw ChronicleError.snapshotCancelled
        }
    }

    private static func collect(
        source: URL,
        vault: URL,
        skip: Set<String>,
        progress: ((String) -> Void)?,
        isCancelled: (() -> Bool)?
    ) throws -> (items: [WalkItem], skipped: [String]) {
        let rootPath = source.path
        let vaultPath = vault.resolvingSymlinksInPath().path
        let box = SkipBox()
        guard let enumerator = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { url, _ in
                let relative = relativePath(url.path, rootPath)
                if !relative.isEmpty { box.paths.append(relative) }
                return true
            }
        ) else {
            throw ChronicleError.fail("Could not read \(rootPath).")
        }

        var items: [WalkItem] = []
        while let url = enumerator.nextObject() as? URL {
            try stopIfCancelled(isCancelled)
            let name = url.lastPathComponent
            let path = url.path
            let relative = relativePath(path, rootPath)
            if relative.isEmpty { continue }
            guard let info = lstatInfo(path) else {
                box.paths.append(relative)
                continue
            }
            let excluded = skip.contains(name) || path == vaultPath || path.hasPrefix(vaultPath + "/")
            // skipDescendants drops the next directory when the current item is not one.
            // A file, a pipe, or a symlink — including a symlink to a folder — must not call it.
            // Only a real directory has children, and only an excluded directory skips them.
            if excluded {
                if info.kind == "dir" { enumerator.skipDescendants() }
                box.paths.append(relative)
                continue
            }
            progress?(relative)
            switch info.kind {
            case "dir":
                items.append(WalkItem(
                    relative: relative, kind: "dir", mode: info.mode, mtimeNS: info.mtimeNS,
                    size: 0, linkTarget: nil, absolute: path
                ))
            case "link":
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""
                items.append(WalkItem(
                    relative: relative, kind: "link", mode: info.mode, mtimeNS: info.mtimeNS,
                    size: info.size, linkTarget: target, absolute: path
                ))
            case "file":
                items.append(WalkItem(
                    relative: relative, kind: "file", mode: info.mode, mtimeNS: info.mtimeNS,
                    size: info.size, linkTarget: nil, absolute: path
                ))
            default:
                box.paths.append(relative)
            }
        }
        items.sort { $0.relative < $1.relative }
        return (items, box.paths)
    }

    private static func guardDestination(_ dest: URL, source: String, vault: URL, allowInsideSource: Bool) throws {
        let destPath = dest.resolvingSymlinksInPath().path
        let sourcePath = URL(fileURLWithPath: source).resolvingSymlinksInPath().path
        let vaultPath = vault.resolvingSymlinksInPath().path
        if !allowInsideSource && PathGuard.isInside(destPath, of: sourcePath) {
            throw ChronicleError.fail("Chronicle will not write into the watched folder. Choose another place.")
        }
        if PathGuard.isInside(destPath, of: vaultPath) {
            throw ChronicleError.fail("Choose a destination outside the history.")
        }
    }

    private static func destinationURL(_ root: URL, _ relative: String) throws -> URL {
        guard RelPath.isSafe(relative) else {
            throw ChronicleError.fail("Refusing a path that leaves the folder.")
        }
        let url = root.appendingPathComponent(relative)
        let rootPath = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        if full != rootPath && !full.hasPrefix(rootPath + "/") {
            throw ChronicleError.fail("Refusing a path that leaves the folder.")
        }
        return url
    }

    private static func prepareDirectory(_ dir: URL, root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let dirPath = dir.standardizedFileURL.path
        guard dirPath == rootPath || dirPath.hasPrefix(rootPath + "/") else {
            throw ChronicleError.fail("Refusing to write outside the destination.")
        }
        if dirPath == rootPath {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return
        }
        let relative = String(dirPath.dropFirst(rootPath.count + 1))
        var built = rootPath
        for part in relative.split(separator: "/") {
            built += "/" + part
            var info = stat()
            if lstat(built, &info) == 0 {
                if info.st_mode & S_IFMT == S_IFLNK {
                    throw ChronicleError.fail("Refusing to follow a symlink in the destination.")
                }
                if info.st_mode & S_IFMT != S_IFDIR {
                    try FileManager.default.removeItem(atPath: built)
                    try FileManager.default.createDirectory(atPath: built, withIntermediateDirectories: false)
                }
            } else {
                try FileManager.default.createDirectory(atPath: built, withIntermediateDirectories: false)
            }
        }
    }

    private static func writeFile(_ url: URL, entry: Entry, store: ChunkStore) throws {
        if entry.chunks.count != entry.lengths.count {
            throw ChronicleError.fail("\(entry.path) has a broken chunk list.")
        }
        // The original stays until every chunk has been read and the copy is complete.
        let partial = temporaryRestore(url)
        var published = false
        defer {
            if !published { try? FileManager.default.removeItem(at: partial) }
        }
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        do {
            var written = 0
            for (hash, length) in zip(entry.chunks, entry.lengths) {
                let data = try store.read(hash)
                if data.count != length {
                    throw ChronicleError.fail("\(entry.path) changed size inside a chunk.")
                }
                try handle.write(contentsOf: data)
                written += data.count
            }
            try handle.close()
            if Int64(written) != entry.size {
                throw ChronicleError.fail("\(entry.path) did not restore to its recorded size.")
            }
        } catch {
            try? handle.close()
            throw error
        }
        chmod(partial.path, mode_t(entry.mode == 0 ? 0o644 : entry.mode))
        try commitRestore(partial, replacing: url, name: entry.path)
        published = true
    }

    private static func writeLink(_ url: URL, target: String, name: String) throws {
        let partial = temporaryRestore(url)
        var published = false
        defer {
            if !published { try? FileManager.default.removeItem(at: partial) }
        }
        try FileManager.default.createSymbolicLink(atPath: partial.path, withDestinationPath: target)
        try commitRestore(partial, replacing: url, name: name)
        published = true
    }

    /// A sibling of the destination, so the final rename stays on the same drive.
    private static func temporaryRestore(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".chronicle-restore-\(UUID().uuidString)")
    }

    /// Puts a finished copy in place. A file or link already there is replaced by the rename.
    /// A directory is moved aside first and put back if that rename fails.
    private static func commitRestore(_ partial: URL, replacing dest: URL, name: String) throws {
        var info = stat()
        if lstat(dest.path, &info) != 0 {
            try renameItem(partial, to: dest, name: name)
            return
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            let aside = temporaryRestore(dest)
            try renameItem(dest, to: aside, name: name)
            do {
                try renameItem(partial, to: dest, name: name)
            } catch {
                _ = aside.path.withCString { source in
                    dest.path.withCString { target in
                        rename(source, target)
                    }
                }
                try? FileManager.default.removeItem(at: aside)
                throw error
            }
            try? FileManager.default.removeItem(at: aside)
            return
        }
        try renameItem(partial, to: dest, name: name)
    }

    private static func renameItem(_ source: URL, to dest: URL, name: String) throws {
        var reason = ""
        let renamed = source.path.withCString { src in
            dest.path.withCString { dst in
                if rename(src, dst) == 0 { return true }
                reason = String(cString: strerror(errno))
                return false
            }
        }
        if !renamed {
            throw ChronicleError.fail("\(name) could not be put in place (\(reason)).")
        }
    }

    private static func applyMtime(_ path: String, _ mtimeNS: Int64) {
        var seconds = mtimeNS / 1_000_000_000
        var nanos = mtimeNS % 1_000_000_000
        if nanos < 0 {
            seconds -= 1
            nanos += 1_000_000_000
        }
        let when = timespec(tv_sec: time_t(seconds), tv_nsec: Int(nanos))
        var times = [when, when]
        _ = path.withCString { utimensat(AT_FDCWD, $0, &times, AT_SYMLINK_NOFOLLOW) }
    }

    private static func lstatInfo(_ path: String) -> StatInfo? {
        var info = stat()
        if lstat(path, &info) != 0 { return nil }
        let kind: String
        switch info.st_mode & S_IFMT {
        case S_IFREG: kind = "file"
        case S_IFDIR: kind = "dir"
        case S_IFLNK: kind = "link"
        default: kind = "other"
        }
        let mtime = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return StatInfo(kind: kind, mode: UInt32(info.st_mode & 0o777), mtimeNS: mtime, size: Int64(info.st_size))
    }

    private static func isDirectory(_ path: String) -> Bool {
        lstatInfo(path)?.kind == "dir" || {
            var info = stat()
            return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        }()
    }

    private static func relativePath(_ path: String, _ root: String) -> String {
        if let stripped = strip(path, root) { return stripped }
        // The enumerator reports /private/var while the root may be /var.
        // Resolve the parent only, so a symlink keeps its own name.
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let name = URL(fileURLWithPath: path).lastPathComponent
        if parent == resolvedRoot { return name }
        if let under = strip(parent, resolvedRoot), !under.isEmpty {
            return under + "/" + name
        }
        return ""
    }

    private static func strip(_ path: String, _ root: String) -> String? {
        if path == root { return "" }
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return nil
    }

    private static func directoryBytes(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    private static func fileBytes(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return 0 }
        return Int64(values?.fileSize ?? 0)
    }
}
