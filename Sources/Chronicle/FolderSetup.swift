import Darwin
import Foundation

/// Folders the user can leave out before the first snapshot. The list is one level deep.
enum FolderSetup {
    struct Listing: Equatable {
        var names: [String]
        var unreadable: Bool
    }

    /// Directories directly inside `source`, including names that start with a dot.
    /// `contentsOfDirectory(atPath:)` keeps those names. A symlink is not a directory:
    /// the snapshot stores the link and does not follow it.
    static func folders(in source: URL) -> Listing {
        let root = source.resolvingSymlinksInPath().path
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root)
        } catch {
            return Listing(names: [], unreadable: true)
        }
        var folders: [String] = []
        for name in names where isFolderName(name) {
            let path = (root as NSString).appendingPathComponent(name)
            var info = stat()
            if lstat(path, &info) != 0 { continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                folders.append(name)
            }
        }
        return Listing(names: folders.sorted(), unreadable: false)
    }

    static func matching(_ names: [String], query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return names }
        return names.filter { $0.lowercased().contains(needle) }
    }

    /// Names the first snapshot leaves out.
    /// A default stays unless that folder is shown and the user cleared it.
    /// A checked folder is added. Order is the defaults that remain, then the extras in folder order.
    static func skipNames(folders: [String], excluded: Set<String>) -> [String] {
        let shown = Set(folders)
        var names = VaultConfig.defaultSkip.filter { name in
            !shown.contains(name) || excluded.contains(name)
        }
        for folder in folders where excluded.contains(folder) && !names.contains(folder) {
            names.append(folder)
        }
        return sanitize(names)
    }

    static func sanitize(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var kept: [String] = []
        for name in raw where isFolderName(name) && seen.insert(name).inserted {
            kept.append(name)
        }
        return kept
    }

    static func isFolderName(_ name: String) -> Bool {
        if name.isEmpty || name == "." || name == ".." { return false }
        if name.contains("/") || name.contains("\0") { return false }
        return true
    }
}
