import Foundation

struct ChronicleError: LocalizedError, CustomStringConvertible {
    enum Code: Equatable {
        case general
        /// `snapshots/` exists and could not be listed. Matched by identity, not by the sentence.
        case versionListUnreadable
        /// The user stopped the snapshot before its version was saved.
        case snapshotCancelled
    }

    var message: String
    var code: Code
    var errorDescription: String? { message }
    var description: String { message }

    static func fail(_ message: String) -> ChronicleError {
        ChronicleError(message: message, code: .general)
    }

    static var versionListUnreadable: ChronicleError {
        ChronicleError(message: "The version list could not be read.", code: .versionListUnreadable)
    }

    static var snapshotCancelled: ChronicleError {
        ChronicleError(message: "Stopped. The version was not saved.", code: .snapshotCancelled)
    }
}

enum TimeText {
    static func nowISO(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parse(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }

    static func display(_ iso: String) -> String {
        guard let date = parse(iso) else { return iso }
        return display(date)
    }

    static func day(_ date: Date) -> String {
        let day = DateFormatter()
        day.locale = Locale.current
        day.dateStyle = .medium
        day.timeStyle = .none
        return day.string(from: date)
    }

    static func display(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = clock(date)
        if calendar.isDateInToday(date) {
            return "Today \(time)"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday \(time)"
        }
        let day = DateFormatter()
        day.locale = Locale.current
        day.dateStyle = .medium
        day.timeStyle = .short
        return day.string(from: date)
    }

    static func clock(_ date: Date) -> String {
        let time = DateFormatter()
        time.locale = Locale.current
        time.dateStyle = .none
        time.timeStyle = .short
        return time.string(from: date)
    }
}

/// The version list. The newest day stays open. Each earlier day starts collapsed.
struct VersionDay: Identifiable, Equatable {
    var id: String
    var title: String
    var opensFlat: Bool
    var showsHeader: Bool
    var heads: [SnapshotHead]
}

enum VersionDays {
    static func group(_ heads: [SnapshotHead], now: Date = Date(), calendar: Calendar = .current) -> [VersionDay] {
        var order: [String] = []
        var buckets: [String: [SnapshotHead]] = [:]
        var other: [SnapshotHead] = []
        for head in heads {
            guard let date = TimeText.parse(head.created) ?? Vault.Retention.date(from: head.id) else {
                other.append(head)
                continue
            }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(head)
        }
        order.sort(by: >)
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale.current
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateStyle = .medium
        dayFormatter.timeStyle = .none
        var days: [VersionDay] = order.map { key in
            let items = buckets[key] ?? []
            let date = TimeText.parse(items[0].created) ?? Vault.Retention.date(from: items[0].id) ?? now
            let title: String
            if calendar.isDate(date, inSameDayAs: now) {
                title = "Today"
            } else if let previous = calendar.date(byAdding: .day, value: -1, to: now),
                      calendar.isDate(date, inSameDayAs: previous) {
                title = "Yesterday"
            } else {
                title = dayFormatter.string(from: date)
            }
            return VersionDay(id: key, title: title, opensFlat: false, showsHeader: false, heads: items)
        }
        if !other.isEmpty {
            days.append(VersionDay(id: "other", title: "Other", opensFlat: false, showsHeader: false, heads: other))
        }
        let several = days.count > 1
        return days.enumerated().map { index, day in
            var copy = day
            copy.opensFlat = index == 0
            copy.showsHeader = several
            return copy
        }
    }
}

struct PrunedVersion: Equatable {
    var id: String
    var created: Date?
}

/// What one thinning pass deleted. `freed` is chunk and directory bytes no remaining version uses.
struct PruneResult: Equatable {
    var removed: [PrunedVersion]
    var freed: Int64
    var complete: Bool
    var count: Int { removed.count }
    static let none = PruneResult(removed: [], freed: 0, complete: true)
}

struct CleanResult: Equatable {
    var freed: Int64
    var thinning: PruneResult
}

struct ThinningVersion: Codable, Equatable {
    var id: String
    var created: String?
}

/// One thinning pass that removed versions. `freed` is 0 when the pass could not read every version.
struct ThinningPass: Codable, Equatable, Identifiable {
    var at: String
    var versions: [ThinningVersion]
    var freed: Int64
    var complete: Bool

    var id: String {
        "\(at)|\(versions.first?.id ?? "")|\(versions.count)"
    }
}

/// Totals since the first logged pass. The list keeps the newest passes; the totals keep the rest.
struct ThinningLog: Codable, Equatable {
    var since: String
    var removed: Int
    var freed: Int64
    var passes: [ThinningPass]

    static let empty = ThinningLog(since: "", removed: 0, freed: 0, passes: [])
    /// Newest passes kept in the list. Older passes stay in `removed` and `freed`.
    static let keptPasses = 40

    func recording(_ result: PruneResult, at date: Date) -> ThinningLog {
        guard result.count > 0 else { return self }
        let stamp = TimeText.nowISO(date)
        let pass = ThinningPass(
            at: stamp,
            versions: result.removed.map { version in
                ThinningVersion(id: version.id, created: version.created.map(TimeText.nowISO))
            },
            freed: result.complete ? result.freed : 0,
            complete: result.complete
        )
        var next = self
        if next.since.isEmpty { next.since = stamp }
        next.removed += result.count
        if result.complete { next.freed += result.freed }
        next.passes.insert(pass, at: 0)
        if next.passes.count > Self.keptPasses {
            next.passes.removeLast(next.passes.count - Self.keptPasses)
        }
        return next
    }
}

struct ThinningHistory: Equatable {
    var log: ThinningLog
    var readable: Bool
    static let ready = ThinningHistory(log: .empty, readable: true)
}

enum ThinText {
    static func names(_ result: PruneResult) -> [String] {
        result.removed.map { version in
            if let date = version.created { return TimeText.display(date) }
            return "an older version"
        }
    }

    static func sentence(names: [String], freed: Int64, complete: Bool) -> String {
        let what: String
        if names.count >= 5, let first = names.first, let last = names.last {
            what = "Removed \(names.count) older versions, from \(first) through \(last)"
        } else if names.isEmpty {
            what = "Removed older versions"
        } else {
            what = "Removed \(list(names))"
        }
        if !complete {
            return "\(what). A version could not be read, so unused chunks were left in place."
        }
        if freed > 0 {
            return "\(what). Freed \(ByteText.string(freed))."
        }
        return "\(what). Freed nothing. The kept versions still use those bytes."
    }

    static func names(_ pass: ThinningPass) -> [String] {
        pass.versions.map { version in
            if let created = version.created, let date = TimeText.parse(created) {
                return TimeText.display(date)
            }
            return "an older version"
        }
    }

    static func report(_ items: [(name: String, result: PruneResult)], nameEach: Bool) -> String {
        items.compactMap { item -> String? in
            guard item.result.count > 0 else { return nil }
            let line = sentence(names: names(item.result), freed: item.result.freed, complete: item.result.complete)
            return nameEach ? "\(item.name): \(line)" : line
        }.joined(separator: " ")
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            let head = items.dropLast().joined(separator: ", ")
            return "\(head), and \(items[items.count - 1])"
        }
    }
}

enum ThinningText {
    static func total(_ log: ThinningLog) -> String {
        let versions = log.removed == 1 ? "1 version" : "\(log.removed) versions"
        let space = log.freed > 0 ? "Freed \(ByteText.string(log.freed))" : "Freed nothing"
        guard let date = TimeText.parse(log.since) else {
            return "\(versions) · \(space)"
        }
        return "\(TimeText.day(date)) · \(versions) · \(space)"
    }
}

enum ByteText {
    static func string(_ bytes: Int64) -> String {
        let sign = bytes < 0 ? "-" : ""
        let value = Double(abs(bytes))
        switch value {
        case 0..<1_000:
            return "\(bytes) B"
        case 0..<1_000_000:
            return sign + trim(value / 1_000) + " KB"
        case 0..<1_000_000_000:
            return sign + trim(value / 1_000_000) + " MB"
        default:
            return sign + trim(value / 1_000_000_000) + " GB"
        }
    }

    static func percentSaved(stored: Int64, raw: Int64) -> Int? {
        guard raw > stored, raw > 0 else { return nil }
        return Int(((Double(raw - stored) / Double(raw)) * 100).rounded())
    }

    private static func trim(_ value: Double) -> String {
        if value >= 10 { return String(format: "%.0f", value) }
        return String(format: "%.1f", value)
    }
}

enum SnapshotID {
    static func make(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var bytes = [UInt8](repeating: 0, count: 4)
        for index in 0..<4 {
            bytes[index] = UInt8.random(in: 0...255)
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(formatter.string(from: date))-\(hex)"
    }

    static func valid(_ id: String) -> Bool {
        guard id.count == 24 else { return false }
        let chars = Array(id)
        if chars[8] != "-" || chars[15] != "-" { return false }
        for (index, character) in chars.enumerated() where index != 8 && index != 15 {
            if !character.isHexDigit || (character.isLetter && !character.isLowercase) {
                return false
            }
        }
        return true
    }
}

enum RestoreTarget {
    /// The folder a row names. A file names the folder that contains it.
    /// A file at the top of the version has no folder here. A removed folder stays gone.
    static func folder(for row: BrowserRow) -> String? {
        if row.kind == "dir" {
            return row.change == "removed" ? nil : row.path
        }
        guard let slash = row.path.lastIndex(of: "/") else { return nil }
        return String(row.path[..<slash])
    }

    /// The folder to highlight. A listed folder wins. A file highlights the deepest
    /// recorded folder that contains it. A removed folder is not offered.
    static func preferred(row: BrowserRow?, folders: [String]) -> String? {
        guard let row else { return nil }
        let known = Set(folders)
        if row.kind == "dir" {
            guard row.change != "removed", known.contains(row.path) else { return nil }
            return row.path
        }
        var path = row.path
        while let slash = path.lastIndex(of: "/") {
            path = String(path[..<slash])
            if known.contains(path) { return path }
        }
        return nil
    }

    /// A selected folder that has no file row, because it did not change, is still that folder.
    /// A file row keeps the folder `preferred(row:folders:)` already chose.
    static func preferred(path: String?, row: BrowserRow?, folders: [String]) -> String? {
        if let chosen = preferred(row: row, folders: folders) { return chosen }
        guard let path, !path.isEmpty, folders.contains(path) else { return nil }
        return path
    }
}

enum RelPath {
    static func isExcluded(_ path: String, names: Set<String>) -> Bool {
        path.split(separator: "/").contains { names.contains(String($0)) }
    }

    static func isSafe(_ path: String) -> Bool {
        if path.isEmpty || path.hasPrefix("/") || path.contains("\0") { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.isEmpty { return false }
        for part in parts {
            if part.isEmpty || part == "." || part == ".." { return false }
        }
        return true
    }
}

enum SnapshotPlace {
    static func folderName(_ name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Folder" : cleaned
        return base.hasSuffix(".chronicle") ? base : base + ".chronicle"
    }

    /// A folder the user picked, described without reading the disk again.
    static func locate(
        name: String,
        id: String,
        onThisMacRoot: URL,
        chosen: URL?,
        isVolume: Bool,
        isEmpty: Bool,
        isVault: Bool,
        source: URL,
        current: URL?
    ) throws -> URL {
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        guard let chosen else {
            let vault = onThisMacRoot.appendingPathComponent(id, isDirectory: true).standardizedFileURL
            if let current, same(vault, current) {
                throw ChronicleError.fail("Snapshots are already stored on this Mac.")
            }
            if PathGuard.isInside(vault.path, of: sourcePath) {
                throw ChronicleError.fail("Choose a place outside the watched folder.")
            }
            return vault
        }
        let picked = chosen.resolvingSymlinksInPath().standardizedFileURL
        if PathGuard.isInside(picked.path, of: sourcePath) || PathGuard.isInside(sourcePath, of: picked.path) {
            throw ChronicleError.fail("Choose a place outside the watched folder.")
        }
        if isVault {
            if let current, same(picked, current) {
                throw ChronicleError.fail("Snapshots are already stored there.")
            }
            throw ChronicleError.fail("That folder is already a Chronicle history.")
        }
        let vault: URL
        if isVolume {
            vault = unique(picked.appendingPathComponent("Chronicle", isDirectory: true), folderName(name))
        } else if isEmpty {
            vault = picked
        } else {
            vault = unique(picked, folderName(name))
        }
        let vaultPath = vault.standardizedFileURL.path
        if vaultPath == sourcePath || PathGuard.isInside(vaultPath, of: sourcePath) || PathGuard.isInside(sourcePath, of: vaultPath) {
            throw ChronicleError.fail("Choose a place outside the watched folder.")
        }
        if let current {
            let currentPath = current.resolvingSymlinksInPath().standardizedFileURL.path
            if vaultPath == currentPath {
                throw ChronicleError.fail("Snapshots are already stored there.")
            }
            if PathGuard.isInside(vaultPath, of: currentPath) || PathGuard.isInside(currentPath, of: vaultPath) {
                throw ChronicleError.fail("Choose a place outside the current snapshots.")
            }
        }
        return vault
    }

    /// The folder new libraries should use after the user picks `chosen`.
    static func rememberedRoot(chosen: URL, isVolume: Bool, isEmpty: Bool) -> URL {
        let picked = chosen.resolvingSymlinksInPath().standardizedFileURL
        if isVolume { return picked.appendingPathComponent("Chronicle", isDirectory: true) }
        if isEmpty { return picked.deletingLastPathComponent() }
        return picked
    }

    static func child(in root: URL, name: String) -> URL {
        unique(root.standardizedFileURL, folderName(name))
    }

    /// A missing folder on this Mac can still be created. An unplugged drive cannot,
    /// and must not be recreated as an ordinary folder under `/Volumes`.
    static func isReachable(_ path: String) -> Bool {
        if FileManager.default.fileExists(atPath: path) { return true }
        let standard = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        guard standard.hasPrefix("/Volumes/") else { return true }
        let parts = standard.split(separator: "/")
        guard parts.count >= 2, parts[0] == "Volumes" else { return false }
        let volumeRoot = "/Volumes/\(parts[1])"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: volumeRoot, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        let values = try? URL(fileURLWithPath: volumeRoot, isDirectory: true).resourceValues(forKeys: [.isVolumeKey])
        return values?.isVolume == true
    }

    private static func unique(_ parent: URL, _ name: String) -> URL {
        var url = parent.appendingPathComponent(name)
        var number = 2
        let stem = (name as NSString).deletingPathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            url = parent.appendingPathComponent("\(stem) \(number).chronicle")
            number += 1
        }
        return url
    }

    private static func same(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

enum PathGuard {
    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// One path for a folder. Foundation reports both `/var` and `/private/var` as `/var`.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Resolves the parent and keeps the last name, so a symlink is not followed.
    static func canonicalLeaf(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parent = url.deletingLastPathComponent()
        if parent.path == url.path { return canonical(url.path) }
        let resolvedParent = canonical(parent.path)
        let name = url.lastPathComponent
        if name.isEmpty { return resolvedParent }
        return URL(fileURLWithPath: resolvedParent).appendingPathComponent(name).standardizedFileURL.path
    }

    static func isInside(_ path: String, of root: String) -> Bool {
        let child = standardized(path)
        let parent = standardized(root)
        return child == parent || child.hasPrefix(parent + "/")
    }
}

struct Entry: Codable, Equatable {
    var path: String
    var kind: String
    var mode: UInt32
    var mtimeNS: Int64
    var size: Int64
    var chunks: [String]
    var lengths: [Int]
    var target: String?
}

struct SnapshotStats: Codable, Equatable {
    var fileCount: Int = 0
    var dirCount: Int = 0
    var linkCount: Int = 0
    var logicalBytes: Int64 = 0
    var newChunkBytes: Int64 = 0
    var reusedChunkBytes: Int64 = 0
    var unchangedFiles: Int = 0
    var addedFiles: Int = 0
    var changedFiles: Int = 0
    var removedFiles: Int = 0
    var skippedCount: Int = 0
    /// Older copies kept because the current file could not be read.
    var carriedFiles: Int = 0
    /// Files Chronicle could not read and had no older copy for.
    var unreadFiles: Int = 0

    var trackedFiles: Int { fileCount + linkCount }

    var statusLine: String? {
        if carriedFiles == 0 && unreadFiles == 0 { return nil }
        var parts: [String] = []
        if carriedFiles > 0 {
            parts.append("\(carriedFiles) \(carriedFiles == 1 ? "file" : "files") carried forward")
        }
        if unreadFiles > 0 {
            parts.append("\(unreadFiles) \(unreadFiles == 1 ? "file" : "files") unreadable")
        }
        if parts.count == 2 {
            return "Saved, with \(parts[0]) and \(parts[1])"
        }
        return "Saved, with \(parts[0])"
    }

    init() {}

    enum CodingKeys: String, CodingKey {
        case fileCount, dirCount, linkCount, logicalBytes, newChunkBytes, reusedChunkBytes
        case unchangedFiles, addedFiles, changedFiles, removedFiles, skippedCount
        case carriedFiles, unreadFiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileCount = try container.decodeIfPresent(Int.self, forKey: .fileCount) ?? 0
        dirCount = try container.decodeIfPresent(Int.self, forKey: .dirCount) ?? 0
        linkCount = try container.decodeIfPresent(Int.self, forKey: .linkCount) ?? 0
        logicalBytes = try container.decodeIfPresent(Int64.self, forKey: .logicalBytes) ?? 0
        newChunkBytes = try container.decodeIfPresent(Int64.self, forKey: .newChunkBytes) ?? 0
        reusedChunkBytes = try container.decodeIfPresent(Int64.self, forKey: .reusedChunkBytes) ?? 0
        unchangedFiles = try container.decodeIfPresent(Int.self, forKey: .unchangedFiles) ?? 0
        addedFiles = try container.decodeIfPresent(Int.self, forKey: .addedFiles) ?? 0
        changedFiles = try container.decodeIfPresent(Int.self, forKey: .changedFiles) ?? 0
        removedFiles = try container.decodeIfPresent(Int.self, forKey: .removedFiles) ?? 0
        skippedCount = try container.decodeIfPresent(Int.self, forKey: .skippedCount) ?? 0
        carriedFiles = try container.decodeIfPresent(Int.self, forKey: .carriedFiles) ?? 0
        unreadFiles = try container.decodeIfPresent(Int.self, forKey: .unreadFiles) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fileCount, forKey: .fileCount)
        try container.encode(dirCount, forKey: .dirCount)
        try container.encode(linkCount, forKey: .linkCount)
        try container.encode(logicalBytes, forKey: .logicalBytes)
        try container.encode(newChunkBytes, forKey: .newChunkBytes)
        try container.encode(reusedChunkBytes, forKey: .reusedChunkBytes)
        try container.encode(unchangedFiles, forKey: .unchangedFiles)
        try container.encode(addedFiles, forKey: .addedFiles)
        try container.encode(changedFiles, forKey: .changedFiles)
        try container.encode(removedFiles, forKey: .removedFiles)
        try container.encode(skippedCount, forKey: .skippedCount)
        try container.encode(carriedFiles, forKey: .carriedFiles)
        try container.encode(unreadFiles, forKey: .unreadFiles)
    }
}

struct Snapshot: Codable, Equatable {
    var format: String
    var id: String
    var parent: String?
    var created: String
    var label: String
    var reason: String
    var source: String
    var files: [Entry]
    var skipped: [String]
    var stats: SnapshotStats
    /// Root directory record. Absent on a version that still stores `files` inline.
    var tree: String?
    /// Versions removed by retention after this one was saved. Not stored.
    var pruned: Int = 0
    /// Which versions that pass removed, and how many bytes their chunks freed. Not stored.
    var pruneDetail: PruneResult = .none

    enum CodingKeys: String, CodingKey {
        case format, id, parent, created, label, reason, source, files, skipped, stats, tree
    }

    init(
        format: String,
        id: String,
        parent: String?,
        created: String,
        label: String,
        reason: String,
        source: String,
        files: [Entry],
        skipped: [String],
        stats: SnapshotStats,
        tree: String? = nil
    ) {
        self.format = format
        self.id = id
        self.parent = parent
        self.created = created
        self.label = label
        self.reason = reason
        self.source = source
        self.files = files
        self.skipped = skipped
        self.stats = stats
        self.tree = tree
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
        files = try container.decodeIfPresent([Entry].self, forKey: .files) ?? []
        skipped = try container.decodeIfPresent([String].self, forKey: .skipped) ?? []
        stats = try container.decodeIfPresent(SnapshotStats.self, forKey: .stats) ?? SnapshotStats()
        tree = try container.decodeIfPresent(String.self, forKey: .tree)
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
        try container.encode(files, forKey: .files)
        try container.encode(skipped, forKey: .skipped)
        try container.encode(stats, forKey: .stats)
        try container.encodeIfPresent(tree, forKey: .tree)
    }

    func warnings(skipNames: Set<String>) -> (carried: Set<String>, unread: [String]) {
        let found = Self.access(files: files, skipped: skipped, skip: skipNames)
        return (found.carried, skipped.filter { found.unread.contains($0) })
    }

    var head: SnapshotHead {
        SnapshotHead(
            format: format,
            id: id,
            parent: parent,
            created: created,
            label: label,
            reason: reason,
            source: source,
            stats: stats
        )
    }

    /// Manual, first, and command-line snapshots are always kept.
    /// An automatic snapshot is kept when something was added, removed, or changed,
    /// or when the carried and unreadable paths are not the same set as the parent.
    /// Carrying the same unreadable folder forward again is not a new version.
    /// A version that is kept still records those counts.
    /// The sets are the stored skip list, which keeps at most 200 paths.
    static func shouldKeep(
        reason: String,
        stats: SnapshotStats,
        carried: Set<String>,
        unread: Set<String>,
        parentCarried: Set<String>,
        parentUnread: Set<String>
    ) -> Bool {
        if reason == "manual" || reason == "first" || reason == "cli" { return true }
        // Directories count in these totals. A directory modification time
        // does not: Finder moves it by writing a skipped name such as .DS_Store.
        if stats.addedFiles > 0 || stats.changedFiles > 0 || stats.removedFiles > 0 { return true }
        return carried != parentCarried || unread != parentUnread
    }

    /// Paths the version could not read. Carried paths are stored. Unreadable paths are not.
    static func access(
        files: [Entry],
        skipped: [String],
        skip: Set<String>
    ) -> (carried: Set<String>, unread: Set<String>) {
        let stored = Set(files.map(\.path))
        let carried = Set(skipped.filter { stored.contains($0) && !RelPath.isExcluded($0, names: skip) })
        var unread = Set<String>()
        for path in skipped {
            if RelPath.isExcluded(path, names: skip) || stored.contains(path) { continue }
            if files.contains(where: { $0.path == path || $0.path.hasPrefix(path + "/") }) { continue }
            unread.insert(path)
        }
        return (carried, unread)
    }
}

struct HistoryCheck: Equatable {
    struct Problem: Equatable, Identifiable {
        var hash: String
        var kind: String
        var versions: [String]
        var id: String { hash }
    }

    var versionCount: Int
    var chunkCount: Int
    var problems: [Problem]

    var affectedVersionCount: Int {
        Set(problems.flatMap(\.versions)).count
    }

    var summary: String {
        if problems.isEmpty {
            let versions = versionCount == 1 ? "1 version" : "\(versionCount) versions"
            let chunks = chunkCount == 1 ? "1 chunk" : "\(chunkCount) chunks"
            return "History is intact. \(versions), \(chunks)."
        }
        let manifests = problems.filter { $0.kind == "manifest" }
        let directories = problems.filter { $0.kind.hasSuffix("directory") }
        let unread = problems.filter { $0.kind == "unread" }
        let chunks = problems.filter { $0.kind != "manifest" && $0.kind != "unread" && !$0.kind.hasSuffix("directory") }
        var parts: [String] = []
        if !chunks.isEmpty {
            let chunkText = chunks.count == 1 ? "1 damaged or missing chunk affects" : "\(chunks.count) damaged or missing chunks affect"
            let count = Set(chunks.flatMap(\.versions)).count
            let versionText = count == 1 ? "1 version" : "\(count) versions"
            parts.append("\(chunkText) \(versionText).")
        }
        if !unread.isEmpty {
            let text = unread.count == 1 ? "1 chunk could not be read." : "\(unread.count) chunks could not be read."
            parts.append(text)
        }
        if !directories.isEmpty {
            let text = directories.count == 1 ? "1 damaged or missing directory affects" : "\(directories.count) damaged or missing directories affect"
            let count = Set(directories.flatMap(\.versions)).count
            let versionText = count == 1 ? "1 version" : "\(count) versions"
            parts.append("\(text) \(versionText).")
        }
        if !manifests.isEmpty {
            let text = manifests.count == 1 ? "1 version could not be read." : "\(manifests.count) versions could not be read."
            parts.append(text)
        }
        return parts.joined(separator: " ")
    }

    var detail: String {
        let lines = problems.prefix(12).map { problem -> String in
            if problem.kind == "manifest" {
                return "Could not read \(problem.hash)"
            }
            let whereText = problem.versions.joined(separator: ", ")
            if problem.kind.hasSuffix("directory") {
                let kind = problem.kind.hasPrefix("missing") ? "Missing" : "Damaged"
                return "\(kind) directory \(problem.hash.prefix(12))…  \(whereText)"
            }
            if problem.kind == "unread" {
                return "Could not read \(problem.hash.prefix(12))…  \(whereText)"
            }
            let kind = problem.kind == "missing" ? "Missing" : "Damaged"
            return "\(kind) \(problem.hash.prefix(12))…  \(whereText)"
        }
        if problems.count > 12 {
            return lines.joined(separator: "\n") + "\nand \(problems.count - 12) more"
        }
        return lines.joined(separator: "\n")
    }
}

struct SnapshotHead: Codable, Equatable, Identifiable {
    var format: String
    var id: String
    var parent: String?
    var created: String
    var label: String
    var reason: String
    var source: String
    var stats: SnapshotStats
}

struct VaultConfig: Codable, Equatable {
    var format: String
    var id: String
    var name: String
    var source: String
    var created: String
    var chunk: ChunkParams
    var skipNames: [String]

    static let defaultSkip = [
        ".DS_Store",
        ".build",
        ".git",
        ".localized",
        ".swiftpm",
        "DerivedData",
        "node_modules",
    ]
}

struct VaultTotals: Equatable {
    var snapshotCount: Int
    var storedBytes: Int64
    var chunkBytes: Int64
    var manifestBytes: Int64
    var rawCopyBytes: Int64
    var latestLogicalBytes: Int64

    var savedPercent: Int? {
        ByteText.percentSaved(stored: storedBytes, raw: rawCopyBytes)
    }
}

struct VersionGlance: Equatable {
    var newBytes: Int64
    var quiet: Bool
}

struct BrowserRow: Identifiable, Equatable {
    var path: String
    var kind: String
    var change: String
    var size: Int64
    var newBytes: Int64
    var chunkCount: Int
    var id: String { path }
}

/// The file list for one version, built without holding every chunk id.
struct VersionBrowse: Equatable {
    var rows: [BrowserRow]
    var folders: [String]
}

/// The folders and files of one version, grouped so a folder opens onto its contents.
/// An unchanged directory stays out of `rows` and is still a folder here when `folders` names it.
enum FileTree {
    struct Node: Equatable, Identifiable {
        var name: String
        var path: String
        var row: BrowserRow?
        /// Nil for a file or link. An empty array is a folder with nothing inside it.
        var children: [Node]?
        var id: String { path }
    }

    static func make(rows: [BrowserRow], folders: [String], query: String = "") -> [Node] {
        var rowByPath: [String: BrowserRow] = [:]
        rowByPath.reserveCapacity(rows.count)
        for row in rows where !row.path.isEmpty && rowByPath[row.path] == nil {
            rowByPath[row.path] = row
        }
        var paths = Set<String>()
        var isDir = Set<String>()
        paths.reserveCapacity(rows.count + folders.count)
        isDir.reserveCapacity(folders.count)

        func ensure(_ path: String, directory: Bool) {
            if path.isEmpty { return }
            paths.insert(path)
            if directory { isDir.insert(path) }
            var parent = path
            while let slash = parent.lastIndex(of: "/") {
                parent = String(parent[..<slash])
                if parent.isEmpty { break }
                isDir.insert(parent)
                if !paths.insert(parent).inserted { break }
            }
        }

        for folder in folders {
            ensure(folder, directory: true)
        }
        for (path, row) in rowByPath {
            ensure(path, directory: row.kind == "dir")
        }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty {
            var keep = Set<String>()
            for path in paths where path.lowercased().contains(needle) {
                var current = path
                while true {
                    if !keep.insert(current).inserted { break }
                    guard let slash = current.lastIndex(of: "/") else { break }
                    current = String(current[..<slash])
                    if current.isEmpty { break }
                }
            }
            paths = keep
        }

        var children: [String: [String]] = [:]
        for path in paths {
            let parent: String
            if let slash = path.lastIndex(of: "/") {
                parent = String(path[..<slash])
            } else {
                parent = ""
            }
            children[parent, default: []].append(path)
        }

        func isFolder(_ path: String) -> Bool {
            if let row = rowByPath[path] { return row.kind == "dir" }
            return isDir.contains(path)
        }

        func ordered(_ lhs: String, _ rhs: String) -> Bool {
            let lhsFolder = isFolder(lhs)
            if lhsFolder != isFolder(rhs) { return lhsFolder }
            let lhsName = leaf(lhs)
            let rhsName = leaf(rhs)
            let compared = lhsName.localizedStandardCompare(rhsName)
            if compared == .orderedSame { return lhs < rhs }
            return compared == .orderedAscending
        }

        func node(_ path: String) -> Node {
            let row = rowByPath[path]
            if isFolder(path) {
                let kids = (children[path] ?? []).sorted(by: ordered).map(node)
                return Node(name: leaf(path), path: path, row: row, children: kids)
            }
            return Node(name: leaf(path), path: path, row: row, children: nil)
        }

        return (children[""] ?? []).sorted(by: ordered).map(node)
    }

    private static func leaf(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}

enum Diff {
    static func rows(
        current: [Entry],
        parent: [Entry]?,
        comparable: Bool,
        carried: Set<String> = [],
        unread: [String] = []
    ) -> [BrowserRow] {
        let previous = entriesByPath(parent ?? [])
        let seen = Set(current.map(\.path))
        var parentsOfFiles = Set<String>()
        for entry in current where entry.kind == "file" || entry.kind == "link" {
            var path = entry.path
            while let slash = path.lastIndex(of: "/") {
                path = String(path[..<slash])
                if !parentsOfFiles.insert(path).inserted { break }
            }
        }
        let carriedDirPrefixes = current.compactMap { entry -> String? in
            guard entry.kind == "dir", carried.contains(entry.path) else { return nil }
            return entry.path + "/"
        }
        var listedPaths = Set<String>()
        var rows: [BrowserRow] = []
        for entry in current where entry.kind == "file" || entry.kind == "link" || entry.kind == "dir" {
            if !listedPaths.insert(entry.path).inserted { continue }
            let old = previous[entry.path]
            var change: String
            if showsCarried(entry, carried: carried, parentsOfFiles: parentsOfFiles, carriedDirPrefixes: carriedDirPrefixes) {
                change = "carried"
            } else if entry.kind == "dir" {
                if !comparable {
                    continue
                } else if old == nil {
                    change = "added"
                } else if old?.kind != "dir" || old?.mode != entry.mode {
                    change = "changed"
                } else {
                    continue
                }
            } else if !comparable {
                change = "same"
            } else if old == nil {
                change = "added"
            } else if old?.chunks != entry.chunks || old?.target != entry.target || old?.size != entry.size || old?.kind != entry.kind || old?.mode != entry.mode {
                change = "changed"
            } else {
                change = "same"
            }
            var fresh: Int64 = 0
            if comparable {
                if let old {
                    let have = Set(old.chunks)
                    for (hash, length) in zip(entry.chunks, entry.lengths) where !have.contains(hash) {
                        fresh += Int64(length)
                    }
                } else {
                    fresh = entry.lengths.reduce(Int64(0)) { $0 + Int64($1) }
                }
            }
            rows.append(BrowserRow(
                path: entry.path,
                kind: entry.kind,
                change: change,
                size: entry.size,
                newBytes: fresh,
                chunkCount: entry.chunks.count
            ))
        }
        if comparable {
            var removed = Set<String>()
            for old in parent ?? [] where (old.kind == "file" || old.kind == "link" || old.kind == "dir") && !seen.contains(old.path) {
                if !removed.insert(old.path).inserted { continue }
                rows.append(BrowserRow(
                    path: old.path,
                    kind: old.kind,
                    change: "removed",
                    size: old.size,
                    newBytes: 0,
                    chunkCount: old.chunks.count
                ))
            }
        }
        var listed = Set(rows.map(\.path))
        for path in unread {
            if !listed.insert(path).inserted { continue }
            rows.append(BrowserRow(
                path: path,
                kind: "file",
                change: "unread",
                size: 0,
                newBytes: 0,
                chunkCount: 0
            ))
        }
        rows.sort { $0.path < $1.path }
        return rows
    }

    /// A file kept because it, or a directory above it, could not be read.
    /// An empty directory that could not be listed stays carried. A directory that still holds files is compared by kind and mode.
    private static func showsCarried(
        _ entry: Entry,
        carried: Set<String>,
        parentsOfFiles: Set<String>,
        carriedDirPrefixes: [String]
    ) -> Bool {
        if entry.kind == "dir" {
            if parentsOfFiles.contains(entry.path) { return false }
            return carried.contains(entry.path)
        }
        if carried.contains(entry.path) { return true }
        return carriedDirPrefixes.contains { entry.path.hasPrefix($0) }
    }

    /// The version row's new-byte count. When the recorded parent still loads, this is the stored figure.
    /// When thinning removed that parent, it is measured against the predecessor the comparison uses.
    static func measure(snap: Snapshot, parent: Snapshot?, substituted: Bool) -> VersionGlance {
        if !substituted {
            let stats = snap.stats
            let quiet = stats.newChunkBytes == 0 && stats.addedFiles == 0 && stats.changedFiles == 0 && stats.removedFiles == 0
            return VersionGlance(newBytes: stats.newChunkBytes, quiet: quiet)
        }
        let current = entriesByPath(snap.files)
        let previous = entriesByPath(parent?.files ?? [])
        var added = 0
        var changed = 0
        var removed = 0
        for (path, entry) in current where entry.kind == "file" || entry.kind == "link" || entry.kind == "dir" {
            guard let old = previous[path] else {
                added += 1
                continue
            }
            if old.kind != entry.kind || old.chunks != entry.chunks || old.target != entry.target || old.size != entry.size || old.mode != entry.mode {
                changed += 1
            }
        }
        for (path, entry) in previous where (entry.kind == "file" || entry.kind == "link" || entry.kind == "dir") && current[path] == nil {
            removed += 1
        }
        let newBytes = freshBytes(current: Array(current.values), previous: Array(previous.values))
        let quiet = newBytes == 0 && added == 0 && changed == 0 && removed == 0
        return VersionGlance(newBytes: newBytes, quiet: quiet)
    }

    /// Chunks in this version that the predecessor does not have. A shared chunk counts once.
    private static func freshBytes(current: [Entry], previous: [Entry]) -> Int64 {
        var old = Set<String>()
        for entry in previous {
            for hash in entry.chunks { old.insert(hash) }
        }
        var seen = Set<String>()
        var total: Int64 = 0
        for entry in current {
            for (hash, length) in zip(entry.chunks, entry.lengths) {
                if old.contains(hash) || !seen.insert(hash).inserted { continue }
                total += Int64(length)
            }
        }
        return total
    }

    /// The first entry for a path wins. A repeated path must not crash the comparison.
    private static func entriesByPath(_ entries: [Entry]) -> [String: Entry] {
        var map: [String: Entry] = [:]
        map.reserveCapacity(entries.count)
        for entry in entries where map[entry.path] == nil {
            map[entry.path] = entry
        }
        return map
    }
}

struct Library: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var source: String
    var vault: String
    var policy: String
    var added: String
}

enum BarStatus {
    struct Line: Equatable {
        var title: String
        var canSnapshot: Bool
    }

    /// What the menu bar says about one watched folder.
    static func line(name: String, policy: String, dirty: Bool, sourceExists: Bool, vaultReachable: Bool) -> Line {
        if !sourceExists {
            return Line(title: "\(name) — the folder is missing", canSnapshot: false)
        }
        if !vaultReachable {
            return Line(title: "\(name) — snapshots are unavailable", canSnapshot: false)
        }
        if Policy.seconds(policy) == nil {
            let detail = dirty ? "changes since the last version" : "snapshots are manual"
            return Line(title: "\(name) — \(detail)", canSnapshot: true)
        }
        if dirty {
            return Line(title: "\(name) — changes waiting", canSnapshot: true)
        }
        return Line(title: "\(name) — watching", canSnapshot: true)
    }
}

enum Policy {
    static func seconds(_ name: String) -> TimeInterval? {
        switch name {
        case "quarter": return 15 * 60
        case "hour": return 60 * 60
        case "day": return 24 * 60 * 60
        default: return nil
        }
    }

    static func label(_ name: String) -> String {
        switch name {
        case "quarter": return "Every 15 minutes"
        case "hour": return "Hourly"
        case "day": return "Daily"
        default: return "Manual"
        }
    }

    static func reason(_ name: String) -> String {
        switch name {
        case "first": return "First version"
        case "watch": return "While watching"
        case "cli": return "Command line"
        case "catchup": return "Caught up"
        default: return "Manual"
        }
    }
}

enum JSONFile {
    static func encoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { formatting.insert(.prettyPrinted) }
        encoder.outputFormatting = formatting
        return encoder
    }

    static func write<T: Encodable>(_ value: T, to url: URL, pretty: Bool) throws {
        let data = try encoder(pretty: pretty).encode(value)
        try data.write(to: url, options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }
}
