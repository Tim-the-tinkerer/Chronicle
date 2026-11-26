import Darwin
import Foundation

enum SelfTest {
    static func run() -> String? {
        Vault.retainFilesForTest = true
        let tests: [() -> String?] = [
            testBuzhashLocal,
            testSmallFileIsOneChunk,
            testDeterministicCuts,
            testChunkCutsMatchAcrossFeeds,
            testInsertionKeepsTheTail,
            testDuplicateAndUnchanged,
            testEditStoresAFraction,
            testZerosCompress,
            testRoundTrip,
            testStaleModificationTime,
            testGarbageCollectsOrphans,
            testDamagedChunk,
            testOverwriteWaitsUntilTheRestoreSucceeds,
            testRestoreDirectoryWritesTheFolder,
            testRefusesWatchedFolder,
            testRejectsPathEscape,
            testClosedEditIsVisible,
            testEmptyDirectoryTriggersWatch,
            testManifestIsTheCommit,
            testFailureBeforeManifestRollsBack,
            testStopLeavesThePreviousVersion,
            testCatchUpSavesAVersion,
            testCarriedForwardIsVisible,
            testRepeatedUnreadableFolderDoesNotSave,
            testVerifyHistoryNamesVersions,
            testSnapshotPlace,
            testRelocateKeepsHistory,
            testInterruptedRelocateKeepsOriginal,
            testDamagedManifestIsVerified,
            testUnreadableVersionListFails,
            testMoveRequiresTheSameVersions,
            testCleanupKeepsChunksWhenTheListCannotBeRead,
            testDamagedNewestVersionStillSnapshots,
            testStoredBytesReplaceADamagedChunk,
            testDeleteNamesAnUnreadableVersionList,
            testDuplicatePathsDoNotCrash,
            testBrokenIndexIsRebuilt,
            testHeadWithoutAVersionIsNotListed,
            testEmptyFileListKeepsTreeChunks,
            testOversizedChunkIsSetAside,
            testDamagedSiblingIsReplaced,
            testPendingStaysWhenCleanupCannotFinish,
            testVarAndPrivateVarAreTheSameFolder,
            testNestedFoldersAreBothWatched,
            testEmptyCheckDoesNotBlockTheNextFolder,
            testVaultWriteDoesNotPretendTheFileWasUnreadable,
            testOversizedDirectoryIsNotPublished,
            testSkippedFileDoesNotHideTheFolder,
            testUnchangedDirectoryIsShared,
            testInlineManifestStillRestores,
            testRetentionThinsOldVersions,
            testLabeledVersionsStay,
            testMissingParentUsesTheSurvivingVersion,
            testSymlinkDoesNotHideTheNextFolder,
            testMissingDirectoryRecordIsNamed,
            testMenuBarStatusLines,
            testVersionDaysGroupPreviousDays,
            testThinningSaysWhatItRemoved,
            testThinningHistoryTotalsSinceLoggingBegan,
            testStreamingBrowseMatchesTheDiff,
            testSnapshotLeavesTheFileListEmpty,
        ]
        for test in tests {
            if let error = test() { return error }
        }
        return nil
    }

    private static func testBuzhashLocal() -> String? {
        var mix = SplitMix64(state: 99)
        var original = Data(count: 50_000)
        for index in 0..<original.count {
            original[index] = UInt8(truncatingIfNeeded: mix.next())
        }
        let insertAt = 1_000
        let extra = Data(repeating: 0x5A, count: 40)
        var modified = original
        modified.insert(contentsOf: extra, at: insertAt)
        let left = hashes(original)
        let right = hashes(modified)
        let start = insertAt + extra.count + 32
        for index in start..<original.count {
            if left[index] != right[index + extra.count] {
                return "buzhash: diverged at \(index)"
            }
        }
        return nil
    }

    private static func testSmallFileIsOneChunk() -> String? {
        let data = Data("hello chronicle".utf8)
        guard let parts = try? Chunker.split(data) else { return "chunker: small file threw" }
        if parts.count != 1 || parts[0] != data { return "chunker: a short file should be one chunk" }
        guard let empty = try? Chunker.split(Data()) else { return "chunker: empty threw" }
        if !empty.isEmpty { return "chunker: empty file produced a chunk" }
        return nil
    }

    private static func testDeterministicCuts() -> String? {
        let data = randomData(count: 200_000, seed: 3)
        guard let first = try? Chunker.split(data), let second = try? Chunker.split(data) else {
            return "chunker: split threw"
        }
        if first.map({ Digest.sha256($0) }) != second.map({ Digest.sha256($0) }) {
            return "chunker: the same bytes produced different cuts"
        }
        if first.count < 2 { return "chunker: expected more than one chunk" }
        return nil
    }

    /// A snapshot reads a file in pieces. The cuts have to match a single feed.
    private static func testChunkCutsMatchAcrossFeeds() -> String? {
        let data = randomData(count: 300_000, seed: 7)
        guard let whole = try? Chunker.split(data) else { return "chunker: split threw" }
        let splitter = ChunkSplitter(params: .standard)
        var parts: [Data] = []
        splitter.onChunk = { parts.append($0) }
        var offset = 0
        let steps = [1, 3, 64, 1_000, 8_191, 65_536]
        var step = 0
        do {
            while offset < data.count {
                let count = min(steps[step % steps.count], data.count - offset)
                try splitter.feed(data.subdata(in: offset..<(offset + count)))
                offset += count
                step += 1
            }
            try splitter.finish()
        } catch {
            return "chunker: \(error.localizedDescription)"
        }
        if parts.count != whole.count { return "chunker: \(parts.count) pieces, \(whole.count) at once" }
        for (index, part) in parts.enumerated() where part != whole[index] {
            return "chunker: piece \(index) disagreed"
        }
        return nil
    }

    private static func testInsertionKeepsTheTail() -> String? {
        let original = randomData(count: 1024 * 1024, seed: 11)
        guard let before = try? Chunker.split(original) else { return "chunker: split threw" }
        var modified = original
        modified.insert(contentsOf: Data(repeating: 0xA5, count: 100), at: 20_000)
        guard let after = try? Chunker.split(modified) else { return "chunker: split threw" }
        let oldHashes = Set(before.map { Digest.sha256($0) })
        let shared = after.filter { oldHashes.contains(Digest.sha256($0)) }.reduce(0) { $0 + $1.count }
        let fresh = after.filter { !oldHashes.contains(Digest.sha256($0)) }.reduce(0) { $0 + $1.count }
        if shared * 2 < original.count {
            return "chunker: insertion kept only \(shared) of \(original.count) bytes"
        }
        if fresh == 0 || fresh > original.count / 4 {
            return "chunker: insertion stored \(fresh) new bytes of a \(original.count) byte file"
        }
        return nil
    }

    private static func testDuplicateAndUnchanged() -> String? {
        let root = temp("dup")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let random = randomData(count: 80_000, seed: 5)
            let zeros = Data(count: 200_000)
            try random.write(to: source.appendingPathComponent("random.bin"))
            try random.write(to: source.appendingPathComponent("random-copy.bin"))
            try zeros.write(to: source.appendingPathComponent("zeros.bin"))
            try zeros.write(to: source.appendingPathComponent("zeros-copy.bin"))
            try Data("note".utf8).write(to: source.appendingPathComponent("note.txt"))
            try Data("dot".utf8).write(to: source.appendingPathComponent(".notes"))
            try FileManager.default.createDirectory(at: source.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try Data("git".utf8).write(to: source.appendingPathComponent(".git/config"))
            try Data("junk".utf8).write(to: source.appendingPathComponent(".DS_Store"))
            try FileManager.default.createDirectory(at: source.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
            try Data("mod".utf8).write(to: source.appendingPathComponent("node_modules/pkg/index.js"))
            try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
            let outside = randomData(count: 4096, seed: 8)
            try outside.write(to: root.appendingPathComponent("outside.bin"))
            try FileManager.default.createSymbolicLink(
                atPath: source.appendingPathComponent("alias").path,
                withDestinationPath: root.appendingPathComponent("outside.bin").path
            )
            let noteMtime = mtime(source.appendingPathComponent("note.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "vault: first snapshot was empty"
            }
            let paths = Set(snap.files.map(\.path))
            if paths.contains(".git/config") || paths.contains(".DS_Store") || paths.contains("node_modules/pkg/index.js") {
                return "vault: a skipped path was stored"
            }
            if !paths.contains(".notes") || !paths.contains("empty") || !paths.contains("alias") {
                return "vault: missing .notes, empty, or alias in \(paths.sorted())"
            }
            if snap.files.first(where: { $0.path == "alias" })?.kind != "link" {
                return "vault: symlink was followed"
            }
            let outsideHash = Digest.sha256(outside)
            if snap.files.contains(where: { $0.chunks.contains(outsideHash) }) {
                return "vault: symlink target was copied into the history"
            }
            if snap.stats.newChunkBytes + snap.stats.reusedChunkBytes != snap.stats.logicalBytes {
                return "vault: new \(snap.stats.newChunkBytes) + reused \(snap.stats.reusedChunkBytes) != logical \(snap.stats.logicalBytes)"
            }
            if snap.stats.reusedChunkBytes < 280_000 {
                return "vault: duplicate files stored \(snap.stats.reusedChunkBytes) reused bytes, wanted the copies"
            }
            if snap.stats.addedFiles != snap.stats.fileCount + snap.stats.linkCount + snap.stats.dirCount {
                return "vault: first version did not mark every file and directory added"
            }
            let disk = try Vault.totals(vault).chunkBytes
            guard let again = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "vault: unchanged snapshot was dropped"
            }
            if again.stats.newChunkBytes != 0 || again.stats.addedFiles != 0 || again.stats.changedFiles != 0 || again.stats.removedFiles != 0 {
                return "vault: unchanged folder stored \(again.stats.newChunkBytes) new bytes"
            }
            let diskAfter = try Vault.totals(vault).chunkBytes
            if diskAfter != disk {
                return "vault: unchanged snapshot grew the chunk store by \(diskAfter - disk)"
            }
            if mtime(source.appendingPathComponent("note.txt")) != noteMtime {
                return "vault: snapshot rewrote a source file"
            }
            let totals = try Vault.totals(vault)
            if totals.rawCopyBytes < snap.stats.logicalBytes * 2 {
                return "vault: raw-copy cost \(totals.rawCopyBytes) is not two full copies"
            }
            if totals.chunkBytes >= totals.rawCopyBytes {
                return "vault: history is not smaller than full copies"
            }
        } catch {
            return "vault: \(error.localizedDescription)"
        }
        return nil
    }

    private static func testEditStoresAFraction() -> String? {
        let root = temp("edit")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let original = randomData(count: 512 * 1024, seed: 21)
            try original.write(to: source.appendingPathComponent("movie.bin"))
            _ = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false)
            var edited = original
            edited.insert(contentsOf: Data(repeating: 0xA5, count: 100), at: 20_000)
            try edited.write(to: source.appendingPathComponent("movie.bin"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "edit", reason: "manual", verify: false) else {
                return "edit: no version"
            }
            if snap.stats.newChunkBytes == 0 || snap.stats.newChunkBytes >= Int64(original.count / 3) {
                return "edit: stored \(snap.stats.newChunkBytes) of a \(original.count) byte file"
            }
            let restored = root.appendingPathComponent("restored")
            try Vault.restore(vault: vault, snapshot: snap.id, dest: restored, allowInsideSource: false)
            let got = try Data(contentsOf: restored.appendingPathComponent("movie.bin"))
            if got != edited { return "edit: restore did not match the edited file" }
        } catch {
            return "edit: \(error.localizedDescription)"
        }
        return nil
    }

    private static func testZerosCompress() -> String? {
        let root = temp("zeros")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data(count: 64 * 1024).write(to: source.appendingPathComponent("blank.bin"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "compress: no version"
            }
            let disk = try Vault.totals(vault).chunkBytes
            if disk >= snap.stats.logicalBytes / 4 {
                return "compress: \(disk) bytes on disk for \(snap.stats.logicalBytes) zero bytes"
            }
        } catch {
            return "compress: \(error.localizedDescription)"
        }
        return nil
    }

    private static func testRoundTrip() -> String? {
        let root = temp("round")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try Data("alpha".utf8).write(to: source.appendingPathComponent("sub/a.txt"))
            try Data("beta".utf8).write(to: source.appendingPathComponent("b.txt"))
            try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "b.txt")
            guard let first = try Vault.snapshot(source: source, vault: vault, label: "one", reason: "manual", verify: false) else {
                return "restore: no first version"
            }
            try Data("beta!".utf8).write(to: source.appendingPathComponent("b.txt"))
            try FileManager.default.removeItem(at: source.appendingPathComponent("sub/a.txt"))
            guard let second = try Vault.snapshot(source: source, vault: vault, label: "two", reason: "manual", verify: false) else {
                return "restore: no second version"
            }
            if second.stats.removedFiles < 1 || second.stats.changedFiles < 1 {
                return "restore: expected a removal and a change"
            }
            let oldDest = root.appendingPathComponent("old")
            let newDest = root.appendingPathComponent("new")
            try Vault.restore(vault: vault, snapshot: first.id, dest: oldDest, allowInsideSource: false)
            try Vault.restore(vault: vault, snapshot: second.id, dest: newDest, allowInsideSource: false)
            let oldA = try Data(contentsOf: oldDest.appendingPathComponent("sub/a.txt"))
            let oldB = try Data(contentsOf: oldDest.appendingPathComponent("b.txt"))
            if oldA != Data("alpha".utf8) || oldB != Data("beta".utf8) {
                return "restore: first version bytes changed"
            }
            if FileManager.default.fileExists(atPath: newDest.appendingPathComponent("sub/a.txt").path) {
                return "restore: removed file came back"
            }
            if try Data(contentsOf: newDest.appendingPathComponent("b.txt")) != Data("beta!".utf8) {
                return "restore: second version bytes changed"
            }
            let link = try FileManager.default.destinationOfSymbolicLink(atPath: oldDest.appendingPathComponent("link").path)
            if link != "b.txt" { return "restore: symlink target is \(link)" }
            let one = root.appendingPathComponent("just-b.txt")
            try Vault.restoreFile(vault: vault, snapshot: first.id, path: "b.txt", dest: one, allowInsideSource: false)
            if try Data(contentsOf: one) != Data("beta".utf8) { return "restore: single file bytes changed" }
        } catch {
            return "restore: \(error.localizedDescription)"
        }
        return nil
    }

    private static func testStaleModificationTime() -> String? {
        let root = temp("stale")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let file = source.appendingPathComponent("note.txt")
            try Data("one".utf8).write(to: file)
            guard let first = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "stale: no first version"
            }
            guard let stamp = mtime(file) else { return "stale: no mtime" }
            try Data("two".utf8).write(to: file)
            if !setMtime(file, stamp) { return "stale: could not put the mtime back" }
            guard let trusted = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "stale: trusted snapshot missing"
            }
            let trustedEntry = trusted.files.first { $0.path == "note.txt" }
            let firstEntry = first.files.first { $0.path == "note.txt" }
            if trustedEntry?.chunks != firstEntry?.chunks {
                return "stale: same size and mtime should reuse the previous chunks"
            }
            guard let checked = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: true) else {
                return "stale: verify snapshot missing"
            }
            if checked.files.first(where: { $0.path == "note.txt" })?.chunks == firstEntry?.chunks {
                return "stale: re-read missed the new bytes"
            }
            let dest = root.appendingPathComponent("out.txt")
            try Vault.restoreFile(vault: vault, snapshot: checked.id, path: "note.txt", dest: dest, allowInsideSource: false)
            if try Data(contentsOf: dest) != Data("two".utf8) { return "stale: verified restore was not the new bytes" }
        } catch {
            return "stale: \(error.localizedDescription)"
        }
        return nil
    }

    private static func testGarbageCollectsOrphans() -> String? {
        let root = temp("gc")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let secret = randomData(count: 20_000, seed: 44)
            try secret.write(to: source.appendingPathComponent("secret.bin"))
            try Data("keep".utf8).write(to: source.appendingPathComponent("keep.txt"))
            guard let first = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "gc: no first version"
            }
            let secretHash = first.files.first { $0.path == "secret.bin" }?.chunks.first
            guard let secretHash else { return "gc: secret has no chunk" }
            try FileManager.default.removeItem(at: source.appendingPathComponent("secret.bin"))
            guard let second = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "gc: no second version"
            }
            _ = try Vault.delete(vault: vault, id: first.id)
            let shard = vault.appendingPathComponent("chunks").appendingPathComponent(String(secretHash.prefix(2))).appendingPathComponent(secretHash)
            if FileManager.default.fileExists(atPath: shard.path) {
                return "gc: unreferenced chunk remains"
            }
            let dest = root.appendingPathComponent("kept")
            try Vault.restore(vault: vault, snapshot: second.id, dest: dest, allowInsideSource: false)
            if try Data(contentsOf: dest.appendingPathComponent("keep.txt")) != Data("keep".utf8) {
                return "gc: surviving version lost its file"
            }
            do {
                try Vault.restore(vault: vault, snapshot: first.id, dest: root.appendingPathComponent("gone"), allowInsideSource: false)
                return "gc: deleted version still restored"
            } catch {
                return nil
            }
        } catch {
            return "gc: \(error.localizedDescription)"
        }
    }

    private static func testDamagedChunk() -> String? {
        let root = temp("damage")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try randomData(count: 12_000, seed: 70).write(to: source.appendingPathComponent("file.bin"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "damage: no version"
            }
            guard let hash = snap.files.first(where: { $0.kind == "file" })?.chunks.first else {
                return "damage: no chunk"
            }
            let url = vault.appendingPathComponent("chunks").appendingPathComponent(String(hash.prefix(2))).appendingPathComponent(hash)
            var raw = try Data(contentsOf: url)
            raw[raw.count - 1] ^= 0xFF
            try raw.write(to: url)
            do {
                try Vault.restore(vault: vault, snapshot: snap.id, dest: root.appendingPathComponent("out"), allowInsideSource: false)
                return "damage: a flipped chunk restored"
            } catch {
                return nil
            }
        } catch {
            return "damage: \(error.localizedDescription)"
        }
    }

    /// A restore approved over an existing file leaves that file in place when a chunk cannot be read.
    private static func testOverwriteWaitsUntilTheRestoreSucceeds() -> String? {
        let root = temp("overwrite")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        let dest = root.appendingPathComponent("note.txt")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("saved".utf8).write(to: source.appendingPathComponent("note.txt"))
            try FileManager.default.createSymbolicLink(
                atPath: source.appendingPathComponent("alias").path,
                withDestinationPath: "note.txt"
            )
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "overwrite: no version"
            }
            try Data("original".utf8).write(to: dest)
            try Vault.restoreFile(vault: vault, snapshot: snap.id, path: "note.txt", dest: dest, allowInsideSource: false)
            if try Data(contentsOf: dest) != Data("saved".utf8) {
                return "overwrite: the saved bytes were not written"
            }
            try Data("original".utf8).write(to: dest)
            guard let hash = snap.files.first(where: { $0.path == "note.txt" })?.chunks.first else {
                return "overwrite: no chunk"
            }
            let chunk = chunkFile(vault, hash)
            var raw = try Data(contentsOf: chunk)
            raw[raw.count - 1] ^= 0xFF
            try raw.write(to: chunk)
            do {
                try Vault.restoreFile(vault: vault, snapshot: snap.id, path: "note.txt", dest: dest, allowInsideSource: false)
                return "overwrite: a damaged chunk replaced the file"
            } catch {
                if !error.localizedDescription.hasPrefix("Damaged chunk") {
                    return "overwrite: \(error.localizedDescription)"
                }
            }
            if try Data(contentsOf: dest) != Data("original".utf8) {
                return "overwrite: the original file was lost"
            }
            if try leftovers(root) {
                return "overwrite: a temporary file was left behind"
            }
            let folder = root.appendingPathComponent("tree")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("keep-me".utf8).write(to: folder.appendingPathComponent("note.txt"))
            do {
                try Vault.restore(vault: vault, snapshot: snap.id, dest: folder, allowInsideSource: false)
                return "overwrite: a damaged folder restore replaced the file"
            } catch {
                if !error.localizedDescription.hasPrefix("Damaged chunk") {
                    return "overwrite: folder \(error.localizedDescription)"
                }
            }
            if try Data(contentsOf: folder.appendingPathComponent("note.txt")) != Data("keep-me".utf8) {
                return "overwrite: the folder restore removed the original"
            }
            if try leftovers(folder) {
                return "overwrite: a temporary file was left in the folder"
            }
            let linkDest = root.appendingPathComponent("link-here")
            try Data("was a file".utf8).write(to: linkDest)
            try Vault.restoreFile(vault: vault, snapshot: snap.id, path: "alias", dest: linkDest, allowInsideSource: false)
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: linkDest.path)
            if target != "note.txt" { return "overwrite: the link was \(target)" }
            return nil
        } catch {
            return "overwrite: \(error.localizedDescription)"
        }
    }

    /// One folder from a version comes back with the files inside it, and nothing beside it.
    private static func testRestoreDirectoryWritesTheFolder() -> String? {
        let file = BrowserRow(path: "notes/page.txt", kind: "file", change: "same", size: 4, newBytes: 0, chunkCount: 1)
        if RestoreTarget.folder(for: file) != "notes" { return "folder: a nested file restored \(RestoreTarget.folder(for: file) ?? "nothing")" }
        let top = BrowserRow(path: "top.txt", kind: "file", change: "same", size: 3, newBytes: 0, chunkCount: 1)
        if RestoreTarget.folder(for: top) != nil { return "folder: a top file named a folder" }
        let directory = BrowserRow(path: "notes/img", kind: "dir", change: "added", size: 0, newBytes: 0, chunkCount: 0)
        if RestoreTarget.folder(for: directory) != "notes/img" { return "folder: the selected folder was \(RestoreTarget.folder(for: directory) ?? "missing")" }
        let gone = BrowserRow(path: "blank", kind: "dir", change: "removed", size: 0, newBytes: 0, chunkCount: 0)
        if RestoreTarget.folder(for: gone) != nil { return "folder: a removed folder was offered" }
        let folders = ["notes", "notes/img", "keep"]
        let deep = BrowserRow(path: "notes/img/a.txt", kind: "file", change: "same", size: 3, newBytes: 0, chunkCount: 1)
        if RestoreTarget.preferred(row: deep, folders: folders) != "notes/img" {
            return "folder: a nested file offered \(RestoreTarget.preferred(row: deep, folders: folders) ?? "nothing")"
        }
        let missingParent = BrowserRow(path: "notes/missing/a.txt", kind: "file", change: "same", size: 1, newBytes: 0, chunkCount: 1)
        if RestoreTarget.preferred(row: missingParent, folders: folders) != "notes" {
            return "folder: a missing parent offered \(RestoreTarget.preferred(row: missingParent, folders: folders) ?? "nothing")"
        }
        if RestoreTarget.preferred(row: top, folders: folders) != nil { return "folder: a top file offered a folder" }
        if RestoreTarget.preferred(row: directory, folders: folders) != "notes/img" {
            return "folder: the chosen folder was \(RestoreTarget.preferred(row: directory, folders: folders) ?? "missing")"
        }
        if RestoreTarget.preferred(row: gone, folders: ["blank"]) != nil { return "folder: a removed folder was still offered" }
        if RestoreTarget.preferred(row: nil, folders: folders) != nil { return "folder: no selection offered a folder" }
        let listed = ["Games", "Games/cyber_llamas", "Audio scripts"]
        if FolderPickPanel.matching(listed, query: "CYBER") != ["Games/cyber_llamas"] {
            return "folder: the list filter missed a folder"
        }
        if FolderPickPanel.matching(listed, query: "audio") != ["Audio scripts"] {
            return "folder: the list filter missed a spaced name"
        }
        if FolderPickPanel.matching(listed, query: "   ").count != listed.count {
            return "folder: a blank filter hid folders"
        }

        let root = temp("folder-restore")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        let dest = root.appendingPathComponent("notes")
        do {
            try FileManager.default.createDirectory(at: source.appendingPathComponent("notes/img"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: source.appendingPathComponent("notes/blank"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: source.appendingPathComponent("keep"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: source.appendingPathComponent("notes-extra"), withIntermediateDirectories: true)
            try Data("page".utf8).write(to: source.appendingPathComponent("notes/page.txt"))
            try Data("img".utf8).write(to: source.appendingPathComponent("notes/img/a.txt"))
            try Data("aaa".utf8).write(to: source.appendingPathComponent("keep/a.txt"))
            try Data("top".utf8).write(to: source.appendingPathComponent("top.txt"))
            try Data("nope".utf8).write(to: source.appendingPathComponent("notes-extra/x.txt"))
            try FileManager.default.createSymbolicLink(
                atPath: source.appendingPathComponent("notes/alias").path,
                withDestinationPath: "page.txt"
            )
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "folder: no version"
            }
            try Vault.restoreDirectory(vault: vault, snapshot: snap.id, path: "notes", dest: dest, allowInsideSource: false)
            if try Data(contentsOf: dest.appendingPathComponent("page.txt")) != Data("page".utf8) {
                return "folder: the page was not restored"
            }
            if try Data(contentsOf: dest.appendingPathComponent("img/a.txt")) != Data("img".utf8) {
                return "folder: a nested file was not restored"
            }
            if lstatInfoKind(dest.appendingPathComponent("blank")) != "dir" {
                return "folder: an empty directory was dropped"
            }
            if try FileManager.default.destinationOfSymbolicLink(atPath: dest.appendingPathComponent("alias").path) != "page.txt" {
                return "folder: the link was not restored"
            }
            if FileManager.default.fileExists(atPath: dest.appendingPathComponent("keep/a.txt").path)
                || FileManager.default.fileExists(atPath: dest.appendingPathComponent("top.txt").path)
                || FileManager.default.fileExists(atPath: dest.appendingPathComponent("x.txt").path) {
                return "folder: a file outside the folder was written"
            }
            do {
                try Vault.restoreFile(vault: vault, snapshot: snap.id, path: "notes", dest: root.appendingPathComponent("file"), allowInsideSource: false)
                return "folder: a folder restored as a file"
            } catch {
                if error.localizedDescription != "Choose a file to restore." {
                    return "folder: file restore said \(error.localizedDescription)"
                }
            }
            do {
                try Vault.restoreDirectory(vault: vault, snapshot: snap.id, path: "top.txt", dest: root.appendingPathComponent("top"), allowInsideSource: false)
                return "folder: a file restored as a folder"
            } catch {
                if error.localizedDescription != "Choose a folder to restore." {
                    return "folder: \(error.localizedDescription)"
                }
            }
            do {
                try Vault.restoreDirectory(vault: vault, snapshot: snap.id, path: "missing", dest: root.appendingPathComponent("missing"), allowInsideSource: false)
                return "folder: a missing folder was created"
            } catch {
                if error.localizedDescription != "That folder is not in this version." {
                    return "folder: missing said \(error.localizedDescription)"
                }
            }
            do {
                try Vault.restoreDirectory(
                    vault: vault,
                    snapshot: snap.id,
                    path: "notes",
                    dest: source.appendingPathComponent("notes-copy"),
                    allowInsideSource: false
                )
                return "folder: wrote into the watched folder"
            } catch {
                if error.localizedDescription != "Chronicle will not write into the watched folder. Choose another place." {
                    return "folder: watched said \(error.localizedDescription)"
                }
            }
            let again = root.appendingPathComponent("again")
            try FileManager.default.createDirectory(at: again, withIntermediateDirectories: true)
            try Data("keep-me".utf8).write(to: again.appendingPathComponent("page.txt"))
            guard let hash = snap.files.first(where: { $0.path == "notes/page.txt" })?.chunks.first else {
                return "folder: no page chunk"
            }
            let chunk = chunkFile(vault, hash)
            var raw = try Data(contentsOf: chunk)
            raw[raw.count - 1] ^= 0xFF
            try raw.write(to: chunk)
            do {
                try Vault.restoreDirectory(vault: vault, snapshot: snap.id, path: "notes", dest: again, allowInsideSource: false)
                return "folder: a damaged file replaced the original"
            } catch {
                if !error.localizedDescription.hasPrefix("Damaged chunk") {
                    return "folder: damage said \(error.localizedDescription)"
                }
            }
            if try Data(contentsOf: again.appendingPathComponent("page.txt")) != Data("keep-me".utf8) {
                return "folder: the damaged file removed the original"
            }
            if try Data(contentsOf: again.appendingPathComponent("img/a.txt")) != Data("img".utf8) {
                return "folder: a file before the damaged one was lost"
            }
            return nil
        } catch {
            return "folder: \(error.localizedDescription)"
        }
    }

    private static func leftovers(_ directory: URL) throws -> Bool {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names.contains { $0.hasPrefix(".chronicle-restore-") }
    }

    private static func testRefusesWatchedFolder() -> String? {
        let root = temp("refuse")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("safe".utf8).write(to: source.appendingPathComponent("a.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "refuse: no version"
            }
            do {
                try Vault.restore(vault: vault, snapshot: snap.id, dest: source, allowInsideSource: false)
                return "refuse: restore wrote into the watched folder"
            } catch {
                let text = try Data(contentsOf: source.appendingPathComponent("a.txt"))
                if text != Data("safe".utf8) { return "refuse: source bytes changed" }
                return nil
            }
        } catch {
            return "refuse: \(error.localizedDescription)"
        }
    }

    private static func testRejectsPathEscape() -> String? {
        let root = temp("escape")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("inside".utf8).write(to: source.appendingPathComponent("a.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "escape: no version"
            }
            var broken = snap
            broken.files = [Entry(
                path: "../escape.txt",
                kind: "file",
                mode: 0o644,
                mtimeNS: 0,
                size: snap.files[0].size,
                chunks: snap.files[0].chunks,
                lengths: snap.files[0].lengths,
                target: nil
            )]
            let body = vault.appendingPathComponent("snapshots").appendingPathComponent(snap.id + ".json")
            try JSONFile.write(broken, to: body, pretty: false)
            let dest = root.appendingPathComponent("dest")
            do {
                try Vault.restore(vault: vault, snapshot: snap.id, dest: dest, allowInsideSource: false)
                return "escape: restore accepted ../"
            } catch {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.txt").path) {
                    return "escape: wrote outside the destination"
                }
                return nil
            }
        } catch {
            return "escape: \(error.localizedDescription)"
        }
    }

    private static func testClosedEditIsVisible() -> String? {
        let root = temp("closed")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("draft".utf8).write(to: source.appendingPathComponent("draft.txt"))
            guard try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) != nil else {
                return "probe: first snapshot was empty"
            }
            let quiet = try Vault.probe(source: source, vault: vault)
            if !quiet.settled || quiet.changed { return "probe: unchanged folder looked dirty" }
            try Data("draft edited".utf8).write(to: source.appendingPathComponent("draft.txt"))
            let edited = try Vault.probe(source: source, vault: vault)
            if !edited.settled || !edited.changed { return "probe: an edit made after the last version was invisible" }
            return nil
        } catch {
            return "probe: \(error.localizedDescription)"
        }
    }

    private static func testEmptyDirectoryTriggersWatch() -> String? {
        let root = temp("emptydir")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        let blank = source.appendingPathComponent("blank")
        do {
            try FileManager.default.createDirectory(at: source.appendingPathComponent("notes"), withIntermediateDirectories: true)
            try Data("page".utf8).write(to: source.appendingPathComponent("notes/page.txt"))
            guard try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) != nil else {
                return "dir: first snapshot was empty"
            }
            try FileManager.default.createDirectory(at: blank, withIntermediateDirectories: true)
            let found = try Vault.probe(source: source, vault: vault)
            if !found.changed { return "dir: a new empty directory was invisible" }
            guard let added = try Vault.snapshot(source: source, vault: vault, label: "", reason: "watch", verify: false) else {
                return "dir: watch dropped a new empty directory"
            }
            if !added.files.contains(where: { $0.path == "blank" && $0.kind == "dir" }) {
                return "dir: empty directory was not stored"
            }
            let rows = Diff.rows(current: added.files, parent: try Vault.load(vault, added.parent ?? "").files, comparable: true)
            if !rows.contains(where: { $0.path == "blank" && $0.change == "added" }) {
                return "dir: empty directory was not shown as added"
            }
            if rows.contains(where: { $0.path == "notes" }) {
                return "dir: an unchanged directory was listed"
            }
            let restored = root.appendingPathComponent("restored")
            try Vault.restore(vault: vault, snapshot: added.id, dest: restored, allowInsideSource: false)
            if lstatInfoKind(restored.appendingPathComponent("blank")) != "dir" {
                return "dir: restore did not recreate the empty directory"
            }
            guard setMtime(blank, 1_700_000_000_000_000_000) else { return "dir: could not set the directory time" }
            if try Vault.snapshot(source: source, vault: vault, label: "", reason: "watch", verify: false) != nil {
                return "dir: a directory modification time alone started a version"
            }
            if try Vault.probe(source: source, vault: vault).changed {
                return "dir: a directory modification time alone looked dirty"
            }
            if chmod(blank.path, 0o700) != 0 { return "dir: chmod failed" }
            guard let modeSnap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "watch", verify: false) else {
                return "dir: a permission change was dropped"
            }
            if modeSnap.files.first(where: { $0.path == "blank" })?.mode != 0o700 {
                return "dir: permission bits were not stored"
            }
            let modeRows = Diff.rows(current: modeSnap.files, parent: try Vault.load(vault, modeSnap.parent ?? "").files, comparable: true)
            if modeRows.first(where: { $0.path == "blank" })?.change != "changed" {
                return "dir: a directory permission change was not shown"
            }
            let page = source.appendingPathComponent("notes/page.txt")
            if chmod(page.path, 0o600) != 0 { return "dir: could not change a file's permissions" }
            guard let fileMode = try Vault.snapshot(source: source, vault: vault, label: "", reason: "watch", verify: false) else {
                return "dir: a file permission change was dropped"
            }
            let fileRows = Diff.rows(current: fileMode.files, parent: try Vault.load(vault, fileMode.parent ?? "").files, comparable: true)
            if fileRows.first(where: { $0.path == "notes/page.txt" })?.change != "changed" {
                return "dir: a file permission change was not shown"
            }
            try FileManager.default.removeItem(at: blank)
            guard let removed = try Vault.snapshot(source: source, vault: vault, label: "", reason: "watch", verify: false) else {
                return "dir: removing an empty directory was dropped"
            }
            if removed.files.contains(where: { $0.path == "blank" }) {
                return "dir: removed directory is still in the version"
            }
            let gone = Diff.rows(current: removed.files, parent: try Vault.load(vault, removed.parent ?? "").files, comparable: true)
            if !gone.contains(where: { $0.path == "blank" && $0.change == "removed" }) {
                return "dir: removed directory was not shown"
            }
            return nil
        } catch {
            return "dir: \(error.localizedDescription)"
        }
    }

    private static func testManifestIsTheCommit() -> String? {
        let root = temp("commit")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: source.appendingPathComponent("keep.txt"))
            guard try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) != nil else {
                return "commit: first snapshot was empty"
            }
            let fresh = randomData(count: 300, seed: 41)
            try fresh.write(to: source.appendingPathComponent("fresh.bin"))
            Vault.fault = .writingHead
            let snap: Snapshot?
            do {
                snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false)
            } catch {
                return "commit: a head failure unpublished the version (\(error.localizedDescription))"
            }
            guard let snap else { return "commit: version was dropped" }
            let body = vault.appendingPathComponent("snapshots").appendingPathComponent(snap.id + ".json")
            let head = vault.appendingPathComponent("snapshots").appendingPathComponent(snap.id + ".head.json")
            if !FileManager.default.fileExists(atPath: body.path) { return "commit: manifest is missing" }
            if FileManager.default.fileExists(atPath: head.path) { return "commit: head was written after its failure" }
            if FileManager.default.fileExists(atPath: vault.appendingPathComponent("pending").path) {
                return "commit: pending marker was left behind"
            }
            let hash = Digest.sha256(fresh)
            let chunk = vault.appendingPathComponent("chunks").appendingPathComponent(String(hash.prefix(2))).appendingPathComponent(hash)
            if !FileManager.default.fileExists(atPath: chunk.path) { return "commit: new chunk was rolled back" }
            let dest = root.appendingPathComponent("out")
            try Vault.restore(vault: vault, snapshot: snap.id, dest: dest, allowInsideSource: false)
            if try Data(contentsOf: dest.appendingPathComponent("fresh.bin")) != fresh {
                return "commit: restored bytes do not match"
            }
            _ = try Vault.listHeads(vault)
            if !FileManager.default.fileExists(atPath: head.path) { return "commit: listing did not rebuild the head" }
            return nil
        } catch {
            return "commit: \(error.localizedDescription)"
        }
    }

    private static func testFailureBeforeManifestRollsBack() -> String? {
        let root = temp("rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: source.appendingPathComponent("keep.txt"))
            guard let first = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "rollback: first snapshot was empty"
            }
            let fresh = randomData(count: 300, seed: 42)
            try fresh.write(to: source.appendingPathComponent("fresh.bin"))
            Vault.fault = .publishingManifest
            do {
                _ = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false)
                return "rollback: snapshot published a version"
            } catch {
                if error.localizedDescription != "Simulated failure." {
                    return "rollback: \(error.localizedDescription)"
                }
            }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: vault.appendingPathComponent("snapshots").path)) ?? []
            if names.contains(where: { $0.hasSuffix(".partial") }) {
                return "rollback: a partial manifest was left behind"
            }
            if try Vault.listHeads(vault).map(\.id) != [first.id] {
                return "rollback: the failed version appeared"
            }
            let hash = Digest.sha256(fresh)
            let chunk = vault.appendingPathComponent("chunks").appendingPathComponent(String(hash.prefix(2))).appendingPathComponent(hash)
            if FileManager.default.fileExists(atPath: chunk.path) { return "rollback: chunk survived a failed snapshot" }
            if FileManager.default.fileExists(atPath: vault.appendingPathComponent("pending").path) {
                return "rollback: pending marker was left behind"
            }
            let dest = root.appendingPathComponent("out")
            try Vault.restore(vault: vault, snapshot: first.id, dest: dest, allowInsideSource: false)
            if try Data(contentsOf: dest.appendingPathComponent("keep.txt")) != Data("keep".utf8) {
                return "rollback: the previous version changed"
            }
            if FileManager.default.fileExists(atPath: dest.appendingPathComponent("fresh.bin").path) {
                return "rollback: the failed version's file was restored"
            }
            return nil
        } catch {
            return "rollback: \(error.localizedDescription)"
        }
    }

    private static func testStopLeavesThePreviousVersion() -> String? {
        let root = temp("stop")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: source.appendingPathComponent("keep.txt"))
            guard let first = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "stop: first snapshot was empty"
            }
            let fresh = randomData(count: 300, seed: 77)
            try fresh.write(to: source.appendingPathComponent("a-new.bin"))
            try Data("b-new".utf8).write(to: source.appendingPathComponent("b-new.txt"))
            // Each path is reported once, in name order. b-new.txt starts after a-new.bin
            // has been stored. Stopping there discards the new chunk and does not publish.
            let reports = StopReports()
            do {
                _ = try Vault.snapshot(
                    source: source,
                    vault: vault,
                    label: "",
                    reason: "manual",
                    verify: false,
                    progress: { reports.note($0) },
                    isCancelled: { reports.count("b-new.txt") >= 1 }
                )
                return "stop: snapshot published a version"
            } catch let error as ChronicleError {
                if error.code != .snapshotCancelled || error.message != "Stopped. The version was not saved." {
                    return "stop: \(error.message)"
                }
            }
            if reports.count("a-new.bin") < 1 {
                return "stop: a-new.bin was not read before the stop"
            }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: vault.appendingPathComponent("snapshots").path)) ?? []
            if names.contains(where: { $0.hasSuffix(".partial") }) {
                return "stop: a partial manifest was left behind"
            }
            if try Vault.listHeads(vault).map(\.id) != [first.id] {
                return "stop: the stopped version appeared"
            }
            if FileManager.default.fileExists(atPath: chunkFile(vault, Digest.sha256(fresh)).path) {
                return "stop: chunk survived a stopped snapshot"
            }
            if FileManager.default.fileExists(atPath: vault.appendingPathComponent("pending").path) {
                return "stop: pending marker was left behind"
            }
            let dest = root.appendingPathComponent("out")
            try Vault.restore(vault: vault, snapshot: first.id, dest: dest, allowInsideSource: false)
            if try Data(contentsOf: dest.appendingPathComponent("keep.txt")) != Data("keep".utf8) {
                return "stop: the previous version changed"
            }
            if FileManager.default.fileExists(atPath: dest.appendingPathComponent("a-new.bin").path) {
                return "stop: the stopped version's file was restored"
            }
            guard let saved = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "stop: the later snapshot was empty"
            }
            let again = root.appendingPathComponent("out2")
            try Vault.restore(vault: vault, snapshot: saved.id, dest: again, allowInsideSource: false)
            if try Data(contentsOf: again.appendingPathComponent("keep.txt")) != Data("keep".utf8) {
                return "stop: keep.txt was missing from the later version"
            }
            if try Data(contentsOf: again.appendingPathComponent("a-new.bin")) != fresh {
                return "stop: a-new.bin was missing from the later version"
            }
            do {
                _ = try Vault.snapshot(
                    source: source,
                    vault: vault,
                    label: "",
                    reason: "manual",
                    verify: false,
                    isCancelled: { true }
                )
                return "stop: an immediate stop was saved"
            } catch let error as ChronicleError {
                if error.code != .snapshotCancelled || error.message != "Stopped. The version was not saved." {
                    return "stop: \(error.message)"
                }
            }
            if try Vault.listHeads(vault).map(\.id) != [saved.id, first.id] {
                return "stop: versions changed after an immediate stop"
            }
            if FileManager.default.fileExists(atPath: vault.appendingPathComponent("pending").path) {
                return "stop: pending marker survived an immediate stop"
            }
            return nil
        } catch {
            return "stop: \(error.localizedDescription)"
        }
    }

    private static func testCatchUpSavesAVersion() -> String? {
        let root = temp("catchup")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("draft".utf8).write(to: source.appendingPathComponent("draft.txt"))
            guard try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) != nil else {
                return "catchup: first snapshot was empty"
            }
            if try Vault.snapshot(source: source, vault: vault, label: "", reason: "catchup", verify: false) != nil {
                return "catchup: an unchanged folder was saved"
            }
            try Data("draft edited".utf8).write(to: source.appendingPathComponent("draft.txt"))
            guard let edited = try Vault.snapshot(source: source, vault: vault, label: "", reason: "catchup", verify: false) else {
                return "catchup: an edit was not saved"
            }
            if edited.reason != "catchup" { return "catchup: reason was \(edited.reason)" }
            try FileManager.default.createDirectory(at: source.appendingPathComponent("blank"), withIntermediateDirectories: true)
            guard let added = try Vault.snapshot(source: source, vault: vault, label: "", reason: "catchup", verify: false) else {
                return "catchup: a new empty folder was not saved"
            }
            if !added.files.contains(where: { $0.path == "blank" && $0.kind == "dir" }) {
                return "catchup: the empty folder was not stored"
            }
            return nil
        } catch {
            return "catchup: \(error.localizedDescription)"
        }
    }

    private static func testCarriedForwardIsVisible() -> String? {
        let root = temp("carried")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        let secret = source.appendingPathComponent("secret.txt")
        let locked = source.appendingPathComponent("locked.txt")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: source.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try Data("git".utf8).write(to: source.appendingPathComponent(".git/config"))
            try FileManager.default.createDirectory(at: source.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
            try Data("mod".utf8).write(to: source.appendingPathComponent("node_modules/pkg/index.js"))
            try Data("version one".utf8).write(to: secret)
            guard try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) != nil else {
                return "carried: first snapshot was empty"
            }
            try Data("version two".utf8).write(to: secret)
            if chmod(secret.path, 0) != 0 { return "carried: could not hide secret.txt" }
            try Data("nope".utf8).write(to: locked)
            if chmod(locked.path, 0) != 0 { return "carried: could not hide locked.txt" }
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "carried: snapshot was dropped"
            }
            if snap.stats.carriedFiles != 1 || snap.stats.unreadFiles != 1 {
                return "carried: counts were \(snap.stats.carriedFiles) carried and \(snap.stats.unreadFiles) unread"
            }
            if snap.stats.statusLine != "Saved, with 1 file carried forward and 1 file unreadable" {
                return "carried: status was \(snap.stats.statusLine ?? "nil")"
            }
            if snap.files.contains(where: { $0.path.contains(".git") || $0.path.contains("node_modules") }) {
                return "carried: an exclusion was stored"
            }
            let warnings = snap.warnings(skipNames: Set(VaultConfig.defaultSkip))
            if warnings.carried != Set(["secret.txt"]) || warnings.unread != ["locked.txt"] {
                return "carried: warnings were \(warnings)"
            }
            let kept = snap.files.first { $0.path == "secret.txt" }
            let restored = root.appendingPathComponent("out.txt")
            try Vault.restoreFile(vault: vault, snapshot: snap.id, path: "secret.txt", dest: restored, allowInsideSource: false)
            if try Data(contentsOf: restored) != Data("version one".utf8) {
                return "carried: the older copy was not the one stored"
            }
            if kept?.chunks.isEmpty == true { return "carried: the older copy has no chunks" }
            let rows = Diff.rows(
                current: snap.files,
                parent: try Vault.load(vault, snap.parent ?? "").files,
                comparable: true,
                carried: warnings.carried,
                unread: warnings.unread
            )
            if !rows.contains(where: { $0.path == "secret.txt" && $0.change == "carried" }) {
                return "carried: secret.txt was not marked carried"
            }
            if !rows.contains(where: { $0.path == "locked.txt" && $0.change == "unread" }) {
                return "carried: locked.txt was not marked unreadable"
            }
            let raw = try Data(contentsOf: vault.appendingPathComponent("snapshots").appendingPathComponent(snap.id + ".json"))
            var object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] ?? [:]
            var stats = object["stats"] as? [String: Any] ?? [:]
            stats.removeValue(forKey: "carriedFiles")
            stats.removeValue(forKey: "unreadFiles")
            object["stats"] = stats
            let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
            if decoded.stats.carriedFiles != 0 || decoded.stats.unreadFiles != 0 {
                return "carried: an older manifest did not load"
            }
            if object["files"] != nil || (object["tree"] as? String) == nil {
                return "carried: the version listed every file"
            }
            let loaded = try Vault.load(vault, snap.id)
            if loaded.files.count != snap.files.count {
                return "carried: the directory record dropped a file"
            }
            return nil
        } catch {
            return "carried: \(error.localizedDescription)"
        }
    }

    private static func testRepeatedUnreadableFolderDoesNotSave() -> String? {
        let root = temp("sealed")
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        let sealed = source.appendingPathComponent("sealed")
        let hidden = source.appendingPathComponent("never.txt")
        defer {
            _ = chmod(sealed.path, 0o755)
            _ = chmod(hidden.path, 0o644)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: true)
            try Data("inside".utf8).write(to: sealed.appendingPathComponent("inside.txt"))
            try Data("keep".utf8).write(to: source.appendingPathComponent("keep.txt"))
            guard try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) != nil else {
                return "sealed: first snapshot was empty"
            }
            if chmod(sealed.path, 0) != 0 { return "sealed: could not hide the folder" }
            guard let first = try Vault.snapshot(source: source, vault: vault, label: "", reason: "catchup", verify: false) else {
                return "sealed: the first unreadable folder was not saved"
            }
            if first.stats.carriedFiles < 1 {
                return "sealed: carried \(first.stats.carriedFiles)"
            }
            if first.stats.statusLine?.contains("carried forward") != true {
                return "sealed: status was \(first.stats.statusLine ?? "nil")"
            }
            let restored = root.appendingPathComponent("inside.txt")
            try Vault.restoreFile(vault: vault, snapshot: first.id, path: "sealed/inside.txt", dest: restored, allowInsideSource: false)
            if try Data(contentsOf: restored) != Data("inside".utf8) {
                return "sealed: the folder's file was not kept"
            }
            let warnings = first.warnings(skipNames: Set(VaultConfig.defaultSkip))
            let shown = Diff.rows(
                current: first.files,
                parent: try Vault.load(vault, first.parent ?? "").files,
                comparable: true,
                carried: warnings.carried,
                unread: warnings.unread
            )
            if !shown.contains(where: { $0.path == "sealed/inside.txt" && $0.change == "carried" }) {
                return "sealed: the kept file was not marked carried"
            }
            if shown.first(where: { $0.path == "sealed" })?.change != "changed" {
                return "sealed: the folder was \(shown.first(where: { $0.path == "sealed" })?.change ?? "missing")"
            }
            let count = try Vault.listHeads(vault).count
            if try Vault.snapshot(source: source, vault: vault, label: "", reason: "catchup", verify: false) != nil {
                return "sealed: launch catch-up saved the same folder again"
            }
            if try Vault.snapshot(source: source, vault: vault, label: "", reason: "watch", verify: false) != nil {
                return "sealed: an automatic run saved the same folder again"
            }
            let quiet = try Vault.probe(source: source, vault: vault)
            if !quiet.settled || quiet.changed {
                return "sealed: the folder still looked changed"
            }
            if try Vault.listHeads(vault).count != count {
                return "sealed: a repeated folder added a version"
            }
            try Data("x".utf8).write(to: hidden)
            if chmod(hidden.path, 0) != 0 { return "sealed: could not hide never.txt" }
            let due = try Vault.probe(source: source, vault: vault)
            if !due.settled || !due.changed {
                return "sealed: a new unreadable file looked unchanged"
            }
            guard let unread = try Vault.snapshot(source: source, vault: vault, label: "", reason: "catchup", verify: false) else {
                return "sealed: a new unreadable file was not saved"
            }
            if unread.stats.unreadFiles < 1 || unread.stats.carriedFiles < 1 {
                return "sealed: counts were \(unread.stats.carriedFiles) carried and \(unread.stats.unreadFiles) unread"
            }
            if try Vault.snapshot(source: source, vault: vault, label: "", reason: "catchup", verify: false) != nil {
                return "sealed: the same unreadable file saved another version"
            }
            if try Vault.probe(source: source, vault: vault).changed {
                return "sealed: the same unreadable file still looked changed"
            }
            try Data("keep edited".utf8).write(to: source.appendingPathComponent("keep.txt"))
            guard let edited = try Vault.snapshot(source: source, vault: vault, label: "", reason: "catchup", verify: false) else {
                return "sealed: an edit was not saved"
            }
            if edited.stats.carriedFiles < 1 || edited.stats.statusLine?.contains("carried forward") != true {
                return "sealed: the edit dropped the carried files (\(edited.stats.statusLine ?? "nil"))"
            }
            guard let manual = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "sealed: a manual snapshot was dropped"
            }
            if manual.stats.carriedFiles < 1 {
                return "sealed: manual dropped the carried count"
            }
            return nil
        } catch {
            return "sealed: \(error.localizedDescription)"
        }
    }

    private static func testVerifyHistoryNamesVersions() -> String? {
        let root = temp("verify")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let shared = randomData(count: 4_000, seed: 3)
            try shared.write(to: source.appendingPathComponent("a.txt"))
            guard let first = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "verify: first snapshot was empty"
            }
            try Data("other-file".utf8).write(to: source.appendingPathComponent("b.txt"))
            guard let second = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "verify: second snapshot was empty"
            }
            let intact = try Vault.verifyHistory(vault: vault)
            if !intact.problems.isEmpty || intact.versionCount != 2 {
                return "verify: intact history reported \(intact.summary)"
            }
            guard let sharedHash = first.files.first(where: { $0.path == "a.txt" })?.chunks.first else {
                return "verify: a.txt has no chunk"
            }
            let sharedURL = vault.appendingPathComponent("chunks").appendingPathComponent(String(sharedHash.prefix(2))).appendingPathComponent(sharedHash)
            var bytes = try Data(contentsOf: sharedURL)
            bytes[bytes.count - 1] ^= 0xFF
            try bytes.write(to: sharedURL)
            guard let only = second.files.first(where: { $0.path == "b.txt" })?.chunks.first else {
                return "verify: b.txt has no chunk"
            }
            let onlyURL = vault.appendingPathComponent("chunks").appendingPathComponent(String(only.prefix(2))).appendingPathComponent(only)
            try FileManager.default.removeItem(at: onlyURL)
            let report = try Vault.verifyHistory(vault: vault)
            guard let damaged = report.problems.first(where: { $0.hash == sharedHash }) else {
                return "verify: the damaged chunk was not reported"
            }
            if damaged.kind != "damaged" || Set(damaged.versions) != Set([first.id, second.id]) {
                return "verify: damaged chunk affected \(damaged.versions)"
            }
            guard let missing = report.problems.first(where: { $0.hash == only }) else {
                return "verify: the missing chunk was not reported"
            }
            if missing.kind != "missing" || missing.versions != [second.id] {
                return "verify: missing chunk affected \(missing.versions)"
            }
            if report.affectedVersionCount != 2 {
                return "verify: affected \(report.affectedVersionCount) versions"
            }
            if report.summary != "2 damaged or missing chunks affect 2 versions." {
                return "verify: summary was \(report.summary)"
            }
            return nil
        } catch {
            return "verify: \(error.localizedDescription)"
        }
    }

    private static func testSnapshotPlace() -> String? {
        let root = temp("place")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Writing")
        let mac = root.appendingPathComponent("OnThisMac")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
            let home = try SnapshotPlace.locate(
                name: "Writing", id: "ABC", onThisMacRoot: mac, chosen: nil,
                isVolume: false, isEmpty: false, isVault: false, source: source, current: nil
            )
            if home.lastPathComponent != "ABC" || home.deletingLastPathComponent().lastPathComponent != mac.lastPathComponent {
                return "place: on this Mac used \(home.path)"
            }
            let volume = root.appendingPathComponent("Volume")
            let onVolume = try SnapshotPlace.locate(
                name: "Writing", id: "ABC", onThisMacRoot: mac, chosen: volume,
                isVolume: true, isEmpty: false, isVault: false, source: source, current: nil
            )
            let volumeParts = onVolume.standardizedFileURL.pathComponents
            if Array(volumeParts.suffix(2)) != ["Chronicle", "Writing.chronicle"] {
                return "place: volume landed at \(volumeParts.suffix(3).joined(separator: "/"))"
            }
            let empty = root.appendingPathComponent("Empty")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            try Data().write(to: empty.appendingPathComponent(".DS_Store"))
            let emptyVault = try SnapshotPlace.locate(
                name: "Writing", id: "ABC", onThisMacRoot: mac, chosen: empty,
                isVolume: false, isEmpty: true, isVault: false, source: source, current: nil
            )
            if emptyVault.standardizedFileURL.path != empty.standardizedFileURL.path {
                return "place: an empty folder was not used as the history"
            }
            let folder = root.appendingPathComponent("Folder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("note.txt"))
            let nested = try SnapshotPlace.locate(
                name: "Writing", id: "ABC", onThisMacRoot: mac, chosen: folder,
                isVolume: false, isEmpty: false, isVault: false, source: source, current: nil
            )
            if nested.lastPathComponent != "Writing.chronicle" || nested.deletingLastPathComponent().standardizedFileURL.path != folder.standardizedFileURL.path {
                return "place: a used folder landed at \(nested.path)"
            }
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("Writing.chronicle"), withIntermediateDirectories: true)
            let collision = try SnapshotPlace.locate(
                name: "Writing", id: "ABC", onThisMacRoot: mac, chosen: folder,
                isVolume: false, isEmpty: false, isVault: false, source: source, current: nil
            )
            if collision.lastPathComponent != "Writing 2.chronicle" {
                return "place: a name collision landed at \(collision.lastPathComponent)"
            }
            do {
                _ = try SnapshotPlace.locate(
                    name: "Writing", id: "ABC", onThisMacRoot: mac, chosen: source.appendingPathComponent("inside"),
                    isVolume: false, isEmpty: false, isVault: false, source: source, current: nil
                )
                return "place: a folder inside the watched folder was accepted"
            } catch {
                if error.localizedDescription != "Choose a place outside the watched folder." {
                    return "place: inside \(error.localizedDescription)"
                }
            }
            let current = root.appendingPathComponent("Current.chronicle")
            do {
                _ = try SnapshotPlace.locate(
                    name: "Writing", id: "ABC", onThisMacRoot: mac, chosen: current,
                    isVolume: false, isEmpty: false, isVault: true, source: source, current: current
                )
                return "place: the current history was accepted again"
            } catch {
                if error.localizedDescription != "Snapshots are already stored there." {
                    return "place: same \(error.localizedDescription)"
                }
            }
            do {
                _ = try SnapshotPlace.locate(
                    name: "Writing", id: "ABC", onThisMacRoot: mac, chosen: nil,
                    isVolume: false, isEmpty: false, isVault: false, source: source, current: home
                )
                return "place: On this Mac was accepted when the history was already there"
            } catch {
                if error.localizedDescription != "Snapshots are already stored on this Mac." {
                    return "place: home \(error.localizedDescription)"
                }
            }
            let remembered = SnapshotPlace.rememberedRoot(chosen: volume, isVolume: true, isEmpty: false)
            if remembered.lastPathComponent != "Chronicle" {
                return "place: a volume was remembered as \(remembered.lastPathComponent)"
            }
            let child = SnapshotPlace.child(in: remembered, name: "Notes")
            if child.lastPathComponent != "Notes.chronicle" {
                return "place: the next folder was \(child.lastPathComponent)"
            }
            let missingDrive = "/Volumes/ChronicleNoSuchDrive\(UUID().uuidString)/Vault"
            if SnapshotPlace.isReachable(missingDrive) {
                return "place: an unplugged drive looked reachable"
            }
            if !SnapshotPlace.isReachable(root.appendingPathComponent("not-yet").path) {
                return "place: a new folder on this Mac looked unreachable"
            }
            return nil
        } catch {
            return "place: \(error.localizedDescription)"
        }
    }

    private static func testRelocateKeepsHistory() -> String? {
        let root = temp("relocate")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: source.appendingPathComponent("note.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "relocate: no version"
            }
            let dest = root.appendingPathComponent("drive").appendingPathComponent("Writing.chronicle")
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            try Data().write(to: dest.appendingPathComponent(".DS_Store"))
            try Vault.relocate(from: vault, to: dest)
            if FileManager.default.fileExists(atPath: vault.path) {
                return "relocate: the old path remains"
            }
            let heads = try Vault.listHeads(dest)
            if heads.count != 1 || heads[0].id != snap.id {
                return "relocate: the history did not arrive"
            }
            let out = root.appendingPathComponent("out.txt")
            try Vault.restoreFile(vault: dest, snapshot: snap.id, path: "note.txt", dest: out, allowInsideSource: false)
            if try Data(contentsOf: out) != Data("kept".utf8) {
                return "relocate: the restored file changed"
            }
            let format = try String(contentsOf: dest.appendingPathComponent("FORMAT"), encoding: .utf8)
            if format.trimmingCharacters(in: .whitespacesAndNewlines) != AppInfo.format {
                return "relocate: FORMAT did not arrive"
            }
            let occupied = root.appendingPathComponent("busy")
            try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: occupied.appendingPathComponent("x.txt"))
            do {
                try Vault.relocate(from: dest, to: occupied)
                return "relocate: a folder that already had files was accepted"
            } catch {
                if error.localizedDescription != "That folder already has files in it." {
                    return "relocate: occupied \(error.localizedDescription)"
                }
                if !FileManager.default.fileExists(atPath: dest.path) {
                    return "relocate: a refused move removed the history"
                }
            }
            do {
                try Vault.relocate(from: root.appendingPathComponent("missing"), to: root.appendingPathComponent("nope"))
                return "relocate: a missing history was accepted"
            } catch {
                if error.localizedDescription != "Snapshots are unavailable. Plug the drive back in." {
                    return "relocate: missing \(error.localizedDescription)"
                }
            }
            return nil
        } catch {
            return "relocate: \(error.localizedDescription)"
        }
    }

    private static func testInterruptedRelocateKeepsOriginal() -> String? {
        let root = temp("relocate-stop")
        defer {
            Vault.fault = nil
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: source.appendingPathComponent("note.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "relocate: no version to interrupt"
            }
            let dest = root.appendingPathComponent("drive").appendingPathComponent("Writing.chronicle")
            Vault.fault = .copyingHistory
            do {
                try Vault.relocate(from: vault, to: dest)
                return "relocate: an interrupted copy finished"
            } catch {
                if error.localizedDescription != "Simulated failure." {
                    return "relocate: interrupt \(error.localizedDescription)"
                }
            }
            if Vault.fault != nil { return "relocate: the interrupt was not consumed" }
            if !FileManager.default.fileExists(atPath: vault.path) {
                return "relocate: the interrupted copy removed the original"
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                return "relocate: the interrupted copy left a destination"
            }
            let parentNames = (try? FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path)) ?? []
            if parentNames.contains(where: { $0.hasPrefix(".chronicle-moving-") }) {
                return "relocate: the partial copy is still on the destination"
            }
            let out = root.appendingPathComponent("out.txt")
            try Vault.restoreFile(vault: vault, snapshot: snap.id, path: "note.txt", dest: out, allowInsideSource: false)
            if try Data(contentsOf: out) != Data("kept".utf8) {
                return "relocate: the original no longer restores"
            }
            return nil
        } catch {
            return "relocate: \(error.localizedDescription)"
        }
    }

    private static func testDamagedManifestIsVerified() -> String? {
        let root = temp("manifest")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("alpha".utf8).write(to: source.appendingPathComponent("a.txt"))
            guard let first = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "manifest: no first version"
            }
            try Data("beta".utf8).write(to: source.appendingPathComponent("b.txt"))
            guard let second = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "manifest: no second version"
            }
            let snapshots = vault.appendingPathComponent("snapshots")
            try FileManager.default.removeItem(at: snapshots.appendingPathComponent(second.id + ".head.json"))
            try Data("not a version".utf8).write(to: snapshots.appendingPathComponent(second.id + ".json"))
            let heads = try Vault.listHeads(vault)
            if heads.contains(where: { $0.id == second.id }) {
                return "manifest: the version list showed a damaged file"
            }
            if heads.contains(where: { $0.id == first.id }) == false {
                return "manifest: the intact version dropped out of the list"
            }
            let report = try Vault.verifyHistory(vault: vault)
            guard let broken = report.problems.first(where: { $0.kind == "manifest" && $0.hash == second.id }) else {
                return "manifest: verify omitted a damaged version with no index (\(report.summary))"
            }
            if broken.versions != [second.id] {
                return "manifest: the unreadable version was \(broken.versions)"
            }
            if report.problems.contains(where: { $0.kind != "manifest" }) {
                return "manifest: an intact chunk was reported"
            }
            if report.summary != "1 version could not be read." {
                return "manifest: summary was \(report.summary)"
            }
            if !report.detail.contains(second.id) {
                return "manifest: detail omitted the version"
            }
            let dest = root.appendingPathComponent("moved")
            do {
                try Vault.relocate(from: vault, to: dest)
                return "manifest: a damaged history was moved"
            } catch {
                if !error.localizedDescription.contains("The copy is not intact.") {
                    return "manifest: move \(error.localizedDescription)"
                }
            }
            if !FileManager.default.fileExists(atPath: vault.path) {
                return "manifest: the refused move removed the original"
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                return "manifest: the damaged copy was kept"
            }
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            if leftovers.contains(where: { $0.hasPrefix(".chronicle-moving-") }) {
                return "manifest: the partial copy is still there"
            }
            let out = root.appendingPathComponent("out.txt")
            try Vault.restoreFile(vault: vault, snapshot: first.id, path: "a.txt", dest: out, allowInsideSource: false)
            if try Data(contentsOf: out) != Data("alpha".utf8) {
                return "manifest: the intact version no longer restores"
            }
            return nil
        } catch {
            return "manifest: \(error.localizedDescription)"
        }
    }

    private static func testUnreadableVersionListFails() -> String? {
        let root = temp("unlistable")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: source.appendingPathComponent("note.txt"))
            guard try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) != nil else {
                return "verify: no version to hide"
            }
            let snapshots = vault.appendingPathComponent("snapshots")
            try FileManager.default.removeItem(at: snapshots)
            try Data("not a directory".utf8).write(to: snapshots)
            do {
                let report = try Vault.verifyHistory(vault: vault)
                return "verify: an unreadable version list reported \(report.summary)"
            } catch {
                if error.localizedDescription != "The version list could not be read." {
                    return "verify: list \(error.localizedDescription)"
                }
            }
            try FileManager.default.createDirectory(at: source.appendingPathComponent("other"), withIntermediateDirectories: true)
            let blockedVault = root.appendingPathComponent("blocked-vault")
            guard try Vault.snapshot(source: source, vault: blockedVault, label: "", reason: "manual", verify: false) != nil else {
                return "verify: no version to lock"
            }
            let blockedList = blockedVault.appendingPathComponent("snapshots")
            if chmod(blockedList.path, 0) != 0 {
                return "verify: could not hide the version list"
            }
            defer { _ = chmod(blockedList.path, 0o755) }
            do {
                let report = try Vault.verifyHistory(vault: blockedVault)
                return "verify: a locked version list reported \(report.summary)"
            } catch {
                if error.localizedDescription != "The version list could not be read." {
                    return "verify: locked list \(error.localizedDescription)"
                }
            }
            let dest = root.appendingPathComponent("moved")
            do {
                try Vault.relocate(from: vault, to: dest)
                return "verify: a move trusted an unreadable version list"
            } catch {
                if !error.localizedDescription.contains("The copy is not intact.") {
                    return "verify: move \(error.localizedDescription)"
                }
            }
            if !FileManager.default.fileExists(atPath: vault.path) {
                return "verify: the failed check removed the original"
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                return "verify: the failed check kept a destination"
            }
            return nil
        } catch {
            return "verify: \(error.localizedDescription)"
        }
    }

    private static func testMoveRequiresTheSameVersions() -> String? {
        let root = temp("same-versions")
        defer {
            Vault.fault = nil
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("one".utf8).write(to: source.appendingPathComponent("a.txt"))
            guard let first = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "versions: no first version"
            }
            try Data("two".utf8).write(to: source.appendingPathComponent("b.txt"))
            guard try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) != nil else {
                return "versions: no second version"
            }
            let dest = root.appendingPathComponent("drive").appendingPathComponent("Writing.chronicle")
            Vault.fault = .droppingCopiedVersion
            do {
                try Vault.relocate(from: vault, to: dest)
                return "versions: a short copy replaced the original"
            } catch {
                if error.localizedDescription != "The copy does not have the same versions. The original history was left where it is." {
                    return "versions: \(error.localizedDescription)"
                }
            }
            if Vault.fault != nil { return "versions: the short copy was not consumed" }
            if !FileManager.default.fileExists(atPath: vault.path) {
                return "versions: the short copy removed the original"
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                return "versions: the short copy left a destination"
            }
            let parentNames = (try? FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path)) ?? []
            if parentNames.contains(where: { $0.hasPrefix(".chronicle-moving-") }) {
                return "versions: the short copy is still on the destination"
            }
            let out = root.appendingPathComponent("out.txt")
            try Vault.restoreFile(vault: vault, snapshot: first.id, path: "a.txt", dest: out, allowInsideSource: false)
            if try Data(contentsOf: out) != Data("one".utf8) {
                return "versions: the original no longer restores"
            }
            return nil
        } catch {
            return "versions: \(error.localizedDescription)"
        }
    }

    private static func testCleanupKeepsChunksWhenTheListCannotBeRead() -> String? {
        let root = temp("cleanup")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: source.appendingPathComponent("note.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "cleanup: no version"
            }
            guard let hash = snap.files.first(where: { $0.path == "note.txt" })?.chunks.first else {
                return "cleanup: no chunk"
            }
            let chunk = chunkFile(vault, hash)
            let original = try Data(contentsOf: chunk)
            try Data("1".utf8).write(to: vault.appendingPathComponent("pending"))
            let snapshots = vault.appendingPathComponent("snapshots")
            if chmod(snapshots.path, 0) != 0 { return "cleanup: could not hide the version list" }
            defer { _ = chmod(snapshots.path, 0o755) }
            try Vault.heal(vault)
            _ = chmod(snapshots.path, 0o755)
            if try Data(contentsOf: chunk) != original {
                return "cleanup: an unreadable version list lost a chunk"
            }
            let blocked = root.appendingPathComponent("blocked")
            try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: vault, to: blocked.appendingPathComponent("vault"))
            let copy = blocked.appendingPathComponent("vault")
            let copyChunk = chunkFile(copy, hash)
            let copyBytes = try Data(contentsOf: copyChunk)
            try FileManager.default.removeItem(at: copy.appendingPathComponent("snapshots"))
            try Data("not a directory".utf8).write(to: copy.appendingPathComponent("snapshots"))
            try Data("1".utf8).write(to: copy.appendingPathComponent("pending"))
            try Vault.heal(copy)
            if try Data(contentsOf: copyChunk) != copyBytes {
                return "cleanup: a version list that is not a directory lost a chunk"
            }
            let restored = root.appendingPathComponent("out.txt")
            try Vault.restoreFile(vault: vault, snapshot: snap.id, path: "note.txt", dest: restored, allowInsideSource: false)
            if try Data(contentsOf: restored) != Data("kept".utf8) {
                return "cleanup: the version no longer restores"
            }
            return nil
        } catch {
            return "cleanup: \(error.localizedDescription)"
        }
    }

    private static func testDamagedNewestVersionStillSnapshots() -> String? {
        let root = temp("newest")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("one".utf8).write(to: source.appendingPathComponent("a.txt"))
            guard let first = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "newest: no first version"
            }
            try Data("two".utf8).write(to: source.appendingPathComponent("b.txt"))
            guard let second = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "newest: no second version"
            }
            guard let keepHash = first.files.first(where: { $0.path == "a.txt" })?.chunks.first,
                  let extraHash = second.files.first(where: { $0.path == "b.txt" })?.chunks.first else {
                return "newest: missing chunks"
            }
            let keepChunk = try Data(contentsOf: chunkFile(vault, keepHash))
            let extraChunk = try Data(contentsOf: chunkFile(vault, extraHash))
            try Data("not a version".utf8).write(to: vault.appendingPathComponent("snapshots").appendingPathComponent(second.id + ".json"))
            do {
                _ = try Vault.clean(vault)
                return "newest: cleanup deleted chunks around a damaged version"
            } catch {
                if error.localizedDescription != "A version could not be read, so unused chunks were left in place." {
                    return "newest: clean \(error.localizedDescription)"
                }
            }
            let keptAfterClean = try Data(contentsOf: chunkFile(vault, keepHash))
            let extraAfterClean = try Data(contentsOf: chunkFile(vault, extraHash))
            if keptAfterClean != keepChunk || extraAfterClean != extraChunk {
                return "newest: cleanup removed a chunk a damaged version may need"
            }
            try Data("1".utf8).write(to: vault.appendingPathComponent("pending"))
            try Data("three".utf8).write(to: source.appendingPathComponent("c.txt"))
            guard let third = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "newest: a damaged version blocked the next snapshot"
            }
            if third.parent != first.id {
                return "newest: parent was \(third.parent ?? "missing")"
            }
            let keptAfterSnapshot = try Data(contentsOf: chunkFile(vault, keepHash))
            let extraAfterSnapshot = try Data(contentsOf: chunkFile(vault, extraHash))
            if keptAfterSnapshot != keepChunk || extraAfterSnapshot != extraChunk {
                return "newest: the next snapshot removed an older chunk"
            }
            let out = root.appendingPathComponent("out.txt")
            try Vault.restoreFile(vault: vault, snapshot: first.id, path: "a.txt", dest: out, allowInsideSource: false)
            if try Data(contentsOf: out) != Data("one".utf8) { return "newest: the older version changed" }
            try Vault.restoreFile(vault: vault, snapshot: third.id, path: "c.txt", dest: out, allowInsideSource: false)
            if try Data(contentsOf: out) != Data("three".utf8) { return "newest: the new version did not restore" }
            return nil
        } catch {
            return "newest: \(error.localizedDescription)"
        }
    }

    private static func testStoredBytesReplaceADamagedChunk() -> String? {
        let root = temp("rewrite")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("payload".utf8).write(to: source.appendingPathComponent("note.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "rewrite: no version"
            }
            guard let hash = snap.files.first(where: { $0.path == "note.txt" })?.chunks.first else {
                return "rewrite: no chunk"
            }
            let url = chunkFile(vault, hash)
            defer { _ = chmod(url.path, 0o644) }
            if chmod(url.path, 0o000) != 0 { return "rewrite: could not hide the chunk" }
            let blocked = try Vault.verifyHistory(vault: vault)
            if !blocked.problems.contains(where: { $0.hash == hash && $0.kind == "unread" }) {
                return "rewrite: a failed read was \(blocked.problems.map(\.kind))"
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                return "rewrite: a failed read moved the chunk"
            }
            let asideEarly = url.deletingLastPathComponent().appendingPathComponent(hash + ".damaged")
            if FileManager.default.fileExists(atPath: asideEarly.path) {
                return "rewrite: a failed read set the chunk aside"
            }
            if chmod(url.path, 0o644) != 0 { return "rewrite: could not show the chunk" }
            var raw = try Data(contentsOf: url)
            raw[raw.count - 1] ^= 0xFF
            try raw.write(to: url)
            let damaged = try Data(contentsOf: url)
            guard try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: true) != nil else {
                return "rewrite: re-read stored nothing"
            }
            if try Data(contentsOf: url) != damaged {
                return "rewrite: re-read replaced a chunk that was already stored"
            }
            let restored = root.appendingPathComponent("out.txt")
            do {
                try Vault.restoreFile(vault: vault, snapshot: snap.id, path: "note.txt", dest: restored, allowInsideSource: false)
                return "rewrite: restore accepted the damaged chunk"
            } catch {
                if !error.localizedDescription.hasPrefix("Damaged chunk") {
                    return "rewrite: \(error.localizedDescription)"
                }
            }
            let report = try Vault.verifyHistory(vault: vault)
            if !report.problems.contains(where: { $0.hash == hash && $0.kind == "damaged" }) {
                return "rewrite: verify did not name the damaged chunk"
            }
            if FileManager.default.fileExists(atPath: url.path) {
                return "rewrite: the damaged chunk was left in place"
            }
            let aside = url.deletingLastPathComponent().appendingPathComponent(hash + ".damaged")
            if try Data(contentsOf: aside) != damaged {
                return "rewrite: the damaged bytes were not kept"
            }
            _ = try Vault.clean(vault)
            if !FileManager.default.fileExists(atPath: aside.path) {
                return "rewrite: cleanup removed the damaged chunk before a good copy existed"
            }
            do {
                try Vault.restoreFile(vault: vault, snapshot: snap.id, path: "note.txt", dest: restored, allowInsideSource: false)
                return "rewrite: restore accepted a quarantined chunk"
            } catch {
            }
            guard try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: true) != nil else {
                return "rewrite: a missing chunk was not stored"
            }
            try Vault.restoreFile(vault: vault, snapshot: snap.id, path: "note.txt", dest: restored, allowInsideSource: false)
            if try Data(contentsOf: restored) != Data("payload".utf8) {
                return "rewrite: the missing chunk was not written back"
            }
            _ = try Vault.clean(vault)
            if FileManager.default.fileExists(atPath: aside.path) {
                return "rewrite: the repaired chunk left its damaged copy"
            }
            if try Data(contentsOf: url) == damaged {
                return "rewrite: cleanup kept the bad bytes under the chunk name"
            }
            return nil
        } catch {
            return "rewrite: \(error.localizedDescription)"
        }
    }

    /// Delete must recognize an unreadable version list without comparing the sentence.
    private static func testDeleteNamesAnUnreadableVersionList() -> String? {
        let root = temp("delete-list")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        let snapshots = vault.appendingPathComponent("snapshots")
        defer { _ = chmod(snapshots.path, 0o755) }
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: source.appendingPathComponent("note.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "delete: no version"
            }
            guard let hash = snap.files.first?.chunks.first else { return "delete: no chunk" }
            let chunk = chunkFile(vault, hash)
            let before = try Data(contentsOf: chunk)
            // Search works, listing does not. The version file can be removed, then the list cannot be read.
            if chmod(snapshots.path, 0o311) != 0 { return "delete: could not hide the version list" }
            do {
                _ = try Vault.delete(vault: vault, id: snap.id)
                return "delete: an unreadable version list was treated as empty"
            } catch {
                if error.localizedDescription != "That version was deleted. Unused chunks were left in place because the version list could not be read." {
                    return "delete: \(error.localizedDescription)"
                }
                if (error as? ChronicleError)?.code == .versionListUnreadable {
                    return "delete: the list error was not rewritten"
                }
            }
            _ = chmod(snapshots.path, 0o755)
            if FileManager.default.fileExists(atPath: snapshots.appendingPathComponent(snap.id + ".json").path) {
                return "delete: the version file is still there"
            }
            if try Data(contentsOf: chunk) != before {
                return "delete: an unreadable list still freed a chunk"
            }
            if ChronicleError.versionListUnreadable.code != .versionListUnreadable {
                return "delete: the version list error has no identity"
            }
            return nil
        } catch {
            return "delete: \(error.localizedDescription)"
        }
    }

    private static func testDuplicatePathsDoNotCrash() -> String? {
        let root = temp("duplicate")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("one".utf8).write(to: source.appendingPathComponent("a.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "duplicate: no version"
            }
            var body = try Vault.load(vault, snap.id)
            guard let first = body.files.first else { return "duplicate: empty version" }
            body.files.append(first)
            try JSONFile.write(body, to: vault.appendingPathComponent("snapshots").appendingPathComponent(snap.id + ".json"), pretty: false)
            let loaded = try Vault.load(vault, snap.id)
            let rows = Diff.rows(current: loaded.files, parent: loaded.files, comparable: true)
            if rows.filter({ $0.path == "a.txt" }).count != 1 {
                return "duplicate: comparison repeated a path"
            }
            try FileManager.default.removeItem(at: source.appendingPathComponent("a.txt"))
            try Data("two".utf8).write(to: source.appendingPathComponent("b.txt"))
            guard let next = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "duplicate: the next snapshot was dropped"
            }
            if next.parent != snap.id { return "duplicate: parent was \(next.parent ?? "missing")" }
            if next.stats.removedFiles != 1 {
                return "duplicate: a repeated path counted as \(next.stats.removedFiles) removals"
            }
            let gone = Diff.rows(current: next.files, parent: loaded.files, comparable: true, unread: ["gone.txt", "gone.txt"])
            if gone.filter({ $0.path == "a.txt" && $0.change == "removed" }).count != 1 {
                return "duplicate: a removed path was listed twice"
            }
            if gone.filter({ $0.path == "gone.txt" }).count != 1 {
                return "duplicate: an unreadable path was listed twice"
            }
            let out = root.appendingPathComponent("out.txt")
            try Vault.restoreFile(vault: vault, snapshot: snap.id, path: "a.txt", dest: out, allowInsideSource: false)
            if try Data(contentsOf: out) != Data("one".utf8) { return "duplicate: the original file changed" }
            return nil
        } catch {
            return "duplicate: \(error.localizedDescription)"
        }
    }

    private static func testBrokenIndexIsRebuilt() -> String? {
        let root = temp("index")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: source.appendingPathComponent("note.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "index: no version"
            }
            let headURL = vault.appendingPathComponent("snapshots").appendingPathComponent(snap.id + ".head.json")
            try Data("not an index".utf8).write(to: headURL)
            let heads = try Vault.listHeads(vault)
            if !heads.contains(where: { $0.id == snap.id }) {
                return "index: a broken index hid the version"
            }
            let head = try JSONFile.read(SnapshotHead.self, from: headURL)
            if head.id != snap.id { return "index: the rebuilt index has \(head.id)" }
            try Data("more".utf8).write(to: source.appendingPathComponent("more.txt"))
            guard let next = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "index: the next snapshot was dropped"
            }
            if next.parent != snap.id { return "index: parent was \(next.parent ?? "missing")" }
            return nil
        } catch {
            return "index: \(error.localizedDescription)"
        }
    }

    /// A head file without its version file is not a version, and the next open removes it.
    private static func testHeadWithoutAVersionIsNotListed() -> String? {
        let root = temp("orphan-head")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: source.appendingPathComponent("note.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "orphan: no version"
            }
            let directory = vault.appendingPathComponent("snapshots")
            let head = directory.appendingPathComponent(snap.id + ".head.json")
            try FileManager.default.removeItem(at: directory.appendingPathComponent(snap.id + ".json"))
            if try Vault.listHeads(vault).contains(where: { $0.id == snap.id }) {
                return "orphan: a missing version stayed in the list"
            }
            _ = try Vault.heal(vault)
            if FileManager.default.fileExists(atPath: head.path) {
                return "orphan: a head without a version stayed on disk"
            }
            return nil
        } catch {
            return "orphan: \(error.localizedDescription)"
        }
    }

    /// An empty file list still names its chunks through the directory record.
    private static func testEmptyFileListKeepsTreeChunks() -> String? {
        let root = temp("empty-files")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: source.appendingPathComponent("note.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "empty list: no version"
            }
            guard let hash = snap.files.first(where: { $0.path == "note.txt" })?.chunks.first else {
                return "empty list: no chunk"
            }
            var object = try manifestObject(vault, snap.id)
            object["files"] = [Any]()
            let data = try JSONSerialization.data(withJSONObject: object)
            try data.write(to: vault.appendingPathComponent("snapshots").appendingPathComponent(snap.id + ".json"))
            _ = try Vault.clean(vault)
            if !FileManager.default.fileExists(atPath: chunkFile(vault, hash).path) {
                return "empty list: cleanup deleted a chunk the version still names"
            }
            let dest = root.appendingPathComponent("restored")
            try Vault.restore(vault: vault, snapshot: snap.id, dest: dest, allowInsideSource: false)
            if try Data(contentsOf: dest.appendingPathComponent("note.txt")) != Data("kept".utf8) {
                return "empty list: the version did not restore"
            }
            return nil
        } catch {
            return "empty list: \(error.localizedDescription)"
        }
    }

    /// A chunk file larger than the format allows is set aside without being read.
    private static func testOversizedChunkIsSetAside() -> String? {
        let root = temp("huge-chunk")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: source.appendingPathComponent("note.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "huge: no version"
            }
            guard let hash = snap.files.first(where: { $0.path == "note.txt" })?.chunks.first else {
                return "huge: no chunk"
            }
            let url = chunkFile(vault, hash)
            let fd = open(url.path, O_RDWR | O_TRUNC)
            if fd < 0 { return "huge: could not open the chunk" }
            let extended = ftruncate(fd, off_t(ChunkCodec.maxFileBytes + 1))
            close(fd)
            if extended != 0 { return "huge: could not extend the chunk" }
            if chmod(url.path, 0o000) != 0 { return "huge: could not hide the chunk" }
            defer { _ = chmod(url.path, 0o644) }
            let report = try Vault.verifyHistory(vault: vault)
            if !report.problems.contains(where: { $0.hash == hash && $0.kind == "damaged" }) {
                return "huge: a file past the limit was \(report.problems.map(\.kind))"
            }
            if FileManager.default.fileExists(atPath: url.path) {
                return "huge: the oversized chunk was left in place"
            }
            let aside = url.deletingLastPathComponent().appendingPathComponent(hash + ".damaged")
            defer { _ = chmod(aside.path, 0o644) }
            if !FileManager.default.fileExists(atPath: aside.path) {
                return "huge: the oversized chunk was not set aside"
            }
            return nil
        } catch {
            return "huge: \(error.localizedDescription)"
        }
    }

    /// Verify can set a chunk aside even when an older `.damaged` file is already there.
    private static func testDamagedSiblingIsReplaced() -> String? {
        let root = temp("damaged-sibling")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: source.appendingPathComponent("note.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "sibling: no version"
            }
            guard let hash = snap.files.first(where: { $0.path == "note.txt" })?.chunks.first else {
                return "sibling: no chunk"
            }
            let url = chunkFile(vault, hash)
            let aside = url.deletingLastPathComponent().appendingPathComponent(hash + ".damaged")
            try Data("old".utf8).write(to: aside)
            try Data("not a chunk".utf8).write(to: url)
            let report = try Vault.verifyHistory(vault: vault)
            if !report.problems.contains(where: { $0.hash == hash && $0.kind == "damaged" }) {
                return "sibling: the chunk was \(report.problems.map(\.kind))"
            }
            if FileManager.default.fileExists(atPath: url.path) {
                return "sibling: the damaged chunk stayed in place"
            }
            if try Data(contentsOf: aside) != Data("not a chunk".utf8) {
                return "sibling: the older damaged file was left in the way"
            }
            return nil
        } catch {
            return "sibling: \(error.localizedDescription)"
        }
    }

    /// A snapshot does not clear the crash marker when cleanup could not finish.
    private static func testPendingStaysWhenCleanupCannotFinish() -> String? {
        let root = temp("pending-stays")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: source.appendingPathComponent("note.txt"))
            guard let first = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "pending: no version"
            }
            guard let keep = first.files.first(where: { $0.path == "note.txt" })?.chunks.first else {
                return "pending: no chunk"
            }
            let orphanHash = Digest.sha256(Data("orphan-bytes".utf8))
            let orphan = chunkFile(vault, orphanHash)
            try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("orphan".utf8).write(to: orphan)
            let body = vault.appendingPathComponent("snapshots").appendingPathComponent(first.id + ".json")
            if chmod(body.path, 0o000) != 0 { return "pending: could not hide the version" }
            defer { _ = chmod(body.path, 0o644) }
            try Data("1".utf8).write(to: vault.appendingPathComponent("pending"))
            try Data("more".utf8).write(to: source.appendingPathComponent("more.txt"))
            guard try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) != nil else {
                return "pending: the next version was dropped"
            }
            if !FileManager.default.fileExists(atPath: vault.appendingPathComponent("pending").path) {
                return "pending: the crash marker was cleared before cleanup could finish"
            }
            if !FileManager.default.fileExists(atPath: orphan.path) {
                return "pending: an unused chunk was deleted while a version could not be read"
            }
            if !FileManager.default.fileExists(atPath: chunkFile(vault, keep).path) {
                return "pending: a live chunk was deleted"
            }
            if chmod(body.path, 0o644) != 0 { return "pending: could not show the version" }
            _ = try Vault.heal(vault)
            if FileManager.default.fileExists(atPath: vault.appendingPathComponent("pending").path) {
                return "pending: the crash marker stayed after cleanup finished"
            }
            if FileManager.default.fileExists(atPath: orphan.path) {
                return "pending: the unused chunk stayed after cleanup finished"
            }
            if !FileManager.default.fileExists(atPath: chunkFile(vault, keep).path) {
                return "pending: cleanup deleted a live chunk"
            }
            return nil
        } catch {
            return "pending: \(error.localizedDescription)"
        }
    }

    private static func testVarAndPrivateVarAreTheSameFolder() -> String? {
        let alias = PathGuard.canonical("/var")
        let real = PathGuard.canonical("/private/var")
        if alias != real {
            return "watch: /var is \(alias) and /private/var is \(real)"
        }
        let root = PathGuard.canonical("/var/folders")
        let child = PathGuard.canonicalLeaf("/private/var/folders/chronicle-child")
        if child != root + "/chronicle-child" {
            return "watch: \(child) is not \(root)/chronicle-child"
        }
        let link = PathGuard.canonicalLeaf("/private/var/folders/chronicle-link")
        if link != root + "/chronicle-link" {
            return "watch: a symlink name resolved to \(link)"
        }
        return nil
    }

    /// A folder watched inside another folder both hear a change in the inner one.
    private static func testNestedFoldersAreBothWatched() -> String? {
        let roots = ["/Work", "/Work/Notes", "/Work2"]
        let both = FolderWatch.affectedRoots("/Work/Notes/draft.txt", roots: roots)
        if both != ["/Work", "/Work/Notes"] {
            return "watch: a nested folder was \(both)"
        }
        let outer = FolderWatch.affectedRoots("/Work/other.txt", roots: roots)
        if outer != ["/Work"] {
            return "watch: an outer file marked \(outer)"
        }
        let neighbor = FolderWatch.affectedRoots("/Work2/file.txt", roots: roots)
        if neighbor != ["/Work2"] {
            return "watch: a neighbor marked \(neighbor)"
        }
        return nil
    }

    /// An empty automatic check waits out its own interval. The next due folder still runs.
    private static func testEmptyCheckDoesNotBlockTheNextFolder() -> String? {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let quarter: TimeInterval = 15 * 60
        let checked = now.addingTimeInterval(-30)
        let old = now.addingTimeInterval(-quarter - 5)
        let due = AppModel.nextDue(
            [
                ("stuck", quarter, old, checked),
                ("next", quarter, old, nil),
            ],
            now: now
        )
        if due != "next" {
            return "schedule: an empty check left \(due ?? "nothing") due"
        }
        let waiting = AppModel.nextDue(
            [("only", quarter, old, checked)],
            now: now
        )
        if waiting != nil {
            return "schedule: an empty check was due again immediately"
        }
        let open = AppModel.nextDue(
            [("returned", quarter, old, nil)],
            now: now
        )
        if open != "returned" {
            return "schedule: a folder with no empty check was skipped"
        }
        return nil
    }

    /// A chunk that cannot be stored aborts the version. The previous version stays.
    private static func testVaultWriteDoesNotPretendTheFileWasUnreadable() -> String? {
        let root = temp("vault-write")
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        let chunks = vault.appendingPathComponent("chunks")
        defer {
            _ = setDirectoryMode(chunks, 0o755)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: source.appendingPathComponent("keep.txt"))
            guard let first = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "store: first snapshot was empty"
            }
            let fresh = randomData(count: 300, seed: 77)
            try fresh.write(to: source.appendingPathComponent("fresh.bin"))
            if !setDirectoryMode(chunks, 0o555) { return "store: could not lock the chunk folder" }
            do {
                _ = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false)
                return "store: a failed write saved a version"
            } catch {
                let message = error.localizedDescription
                if !message.hasPrefix("Could not store a chunk (") || !message.hasSuffix(").") {
                    return "store: \(message)"
                }
            }
            if !setDirectoryMode(chunks, 0o755) { return "store: could not unlock the chunk folder" }
            if try Vault.listHeads(vault).map(\.id) != [first.id] {
                return "store: the failed version appeared"
            }
            if FileManager.default.fileExists(atPath: chunkFile(vault, Digest.sha256(fresh)).path) {
                return "store: the new chunk was left behind"
            }
            if FileManager.default.fileExists(atPath: vault.appendingPathComponent("pending").path) {
                return "store: pending marker was left behind"
            }
            let dest = root.appendingPathComponent("out")
            try Vault.restore(vault: vault, snapshot: first.id, dest: dest, allowInsideSource: false)
            if try Data(contentsOf: dest.appendingPathComponent("keep.txt")) != Data("keep".utf8) {
                return "store: the previous version changed"
            }
            if FileManager.default.fileExists(atPath: dest.appendingPathComponent("fresh.bin").path) {
                return "store: the failed file was restored"
            }
            return nil
        } catch {
            return "store: \(error.localizedDescription)"
        }
    }

    /// A directory record over the format limit is not published, and the new chunks are removed.
    private static func testOversizedDirectoryIsNotPublished() -> String? {
        let root = temp("wide-dir")
        defer {
            Vault.directoryRecordLimit = nil
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: source.appendingPathComponent("keep.txt"))
            guard let first = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "wide: first snapshot was empty"
            }
            let fresh = randomData(count: 300, seed: 78)
            try fresh.write(to: source.appendingPathComponent("fresh.bin"))
            Vault.directoryRecordLimit = 1
            do {
                _ = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false)
                return "wide: an oversized directory was published"
            } catch {
                if error.localizedDescription != "A directory record is larger than Chronicle allows." {
                    return "wide: \(error.localizedDescription)"
                }
            }
            if Vault.directoryRecordLimit != nil {
                return "wide: the limit stayed set"
            }
            if try Vault.listHeads(vault).map(\.id) != [first.id] {
                return "wide: the failed version appeared"
            }
            if FileManager.default.fileExists(atPath: chunkFile(vault, Digest.sha256(fresh)).path) {
                return "wide: the new chunk was left behind"
            }
            if FileManager.default.fileExists(atPath: vault.appendingPathComponent("pending").path) {
                return "wide: pending marker was left behind"
            }
            guard let again = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "wide: the next snapshot was dropped"
            }
            if again.parent != first.id { return "wide: the next snapshot lost its parent" }
            let dest = root.appendingPathComponent("out")
            try Vault.restore(vault: vault, snapshot: first.id, dest: dest, allowInsideSource: false)
            if try Data(contentsOf: dest.appendingPathComponent("keep.txt")) != Data("keep".utf8) {
                return "wide: the previous version changed"
            }
            return nil
        } catch {
            return "wide: \(error.localizedDescription)"
        }
    }

    private static func setDirectoryMode(_ root: URL, _ mode: mode_t) -> Bool {
        guard FileManager.default.fileExists(atPath: root.path) else { return false }
        var dirs = [root]
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    dirs.append(url)
                }
            }
        }
        return dirs.allSatisfy { chmod($0.path, mode) == 0 }
    }

    /// Counts progress reports. The snapshot calls the closure on the same thread.
    private final class StopReports {
        private var counts: [String: Int] = [:]

        func note(_ path: String) {
            counts[path, default: 0] += 1
        }

        func count(_ path: String) -> Int {
            counts[path] ?? 0
        }
    }

    private static func chunkFile(_ vault: URL, _ hash: String) -> URL {
        vault.appendingPathComponent("chunks").appendingPathComponent(String(hash.prefix(2))).appendingPathComponent(hash)
    }

    private static func testMenuBarStatusLines() -> String? {
        let waiting = BarStatus.line(name: "Writing", policy: "quarter", dirty: true, sourceExists: true, vaultReachable: true)
        if waiting.title != "Writing — changes waiting" || !waiting.canSnapshot {
            return "menu: a dirty folder was \(waiting.title)"
        }
        let calm = BarStatus.line(name: "Writing", policy: "hour", dirty: false, sourceExists: true, vaultReachable: true)
        if calm.title != "Writing — watching" || !calm.canSnapshot {
            return "menu: a quiet folder was \(calm.title)"
        }
        let manual = BarStatus.line(name: "Notes", policy: "manual", dirty: false, sourceExists: true, vaultReachable: true)
        if manual.title != "Notes — snapshots are manual" || !manual.canSnapshot {
            return "menu: a manual folder was \(manual.title)"
        }
        let since = BarStatus.line(name: "Notes", policy: "manual", dirty: true, sourceExists: true, vaultReachable: true)
        if since.title != "Notes — changes since the last version" || !since.canSnapshot {
            return "menu: a changed manual folder was \(since.title)"
        }
        let missing = BarStatus.line(name: "Photos", policy: "quarter", dirty: true, sourceExists: false, vaultReachable: true)
        if missing.canSnapshot || missing.title != "Photos — the folder is missing" {
            return "menu: a missing folder was \(missing.title)"
        }
        let away = BarStatus.line(name: "Drafts", policy: "day", dirty: true, sourceExists: true, vaultReachable: false)
        if away.canSnapshot || away.title != "Drafts — snapshots are unavailable" {
            return "menu: an unplugged drive was \(away.title)"
        }
        return nil
    }

    /// A skipped file used to call skipDescendants, which drops the next directory.
    /// Games/.DS_Store hid Games/cyber_llamas. A skipped directory still hides its own children.
    private static func testSkippedFileDoesNotHideTheFolder() -> String? {
        let root = temp("skip-file")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            let game = source.appendingPathComponent("Games/cyber_llamas")
            try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
            try Data("finder".utf8).write(to: source.appendingPathComponent("Games/.DS_Store"))
            try Data("play".utf8).write(to: game.appendingPathComponent("app.py"))
            try Data("story".utf8).write(to: game.appendingPathComponent("story.py"))
            try Data("finder".utf8).write(to: game.appendingPathComponent(".DS_Store"))
            try Data("read".utf8).write(to: game.appendingPathComponent("README.md"))
            try Data("loc".utf8).write(to: game.appendingPathComponent(".localized"))
            let dataDir = game.appendingPathComponent("data")
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            try Data("sectors".utf8).write(to: dataDir.appendingPathComponent("sectors.json"))
            let real = source.appendingPathComponent("realdir")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try Data("inside".utf8).write(to: real.appendingPathComponent("inside.txt"))
            try FileManager.default.createSymbolicLink(
                atPath: source.appendingPathComponent("linkdir").path,
                withDestinationPath: real.path
            )
            try FileManager.default.createSymbolicLink(
                atPath: source.appendingPathComponent("linkfile").path,
                withDestinationPath: real.appendingPathComponent("inside.txt").path
            )
            try FileManager.default.createSymbolicLink(
                atPath: game.appendingPathComponent("alias").path,
                withDestinationPath: "README.md"
            )
            try FileManager.default.createDirectory(at: source.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try Data("git".utf8).write(to: source.appendingPathComponent(".git/config"))
            try FileManager.default.createDirectory(at: source.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
            try Data("mod".utf8).write(to: source.appendingPathComponent("node_modules/pkg/index.js"))
            try Data("later".utf8).write(to: source.appendingPathComponent("later.txt"))
            let pipe = game.appendingPathComponent("pipe")
            if pipe.path.withCString({ mkfifo($0, 0o644) }) != 0 {
                return "skip: could not create a pipe"
            }
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "skip: snapshot was empty"
            }
            let paths = Set(snap.files.map(\.path))
            let wanted = [
                "Games",
                "Games/cyber_llamas",
                "Games/cyber_llamas/app.py",
                "Games/cyber_llamas/story.py",
                "Games/cyber_llamas/README.md",
                "Games/cyber_llamas/alias",
                "Games/cyber_llamas/data",
                "Games/cyber_llamas/data/sectors.json",
                "realdir",
                "realdir/inside.txt",
                "linkdir",
                "linkfile",
                "later.txt",
            ]
            for path in wanted where !paths.contains(path) {
                return "skip: \(path) was missing from \(paths.sorted())"
            }
            let hidden = [
                ".git", ".git/config",
                "node_modules", "node_modules/pkg", "node_modules/pkg/index.js",
                "Games/.DS_Store", "Games/cyber_llamas/.DS_Store", "Games/cyber_llamas/.localized",
                "Games/cyber_llamas/pipe", "linkdir/inside.txt",
            ]
            for path in hidden where paths.contains(path) {
                return "skip: \(path) was stored"
            }
            if snap.files.first(where: { $0.path == "linkfile" })?.kind != "link"
                || snap.files.first(where: { $0.path == "linkdir" })?.kind != "link"
                || snap.files.first(where: { $0.path == "Games/cyber_llamas/alias" })?.kind != "link" {
                return "skip: a symlink was stored as a file"
            }
            let inside = Digest.sha256(Data("inside".utf8))
            if snap.files.contains(where: { $0.path != "realdir/inside.txt" && $0.chunks.contains(inside) }) {
                return "skip: a symlink target was copied"
            }
            if !snap.skipped.contains("Games/.DS_Store") || !snap.skipped.contains("Games/cyber_llamas/.localized") {
                return "skip: a skipped file was not recorded in \(snap.skipped)"
            }
            if snap.skipped.contains("Games/cyber_llamas/app.py") {
                return "skip: the game file was recorded as skipped"
            }
        } catch {
            return "skip: \(error.localizedDescription)"
        }
        return nil
    }

    /// One changed file rewrites the directories above it. A sibling directory keeps its hash.
    private static func testUnchangedDirectoryIsShared() -> String? {
        let root = temp("trees")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source.appendingPathComponent("keep"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: source.appendingPathComponent("edit"), withIntermediateDirectories: true)
            try Data("aaa".utf8).write(to: source.appendingPathComponent("keep/a.txt"))
            try Data("bbb".utf8).write(to: source.appendingPathComponent("keep/b.txt"))
            try Data("ccc".utf8).write(to: source.appendingPathComponent("edit/c.txt"))
            guard let first = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "tree: no first version"
            }
            try Data("changed".utf8).write(to: source.appendingPathComponent("edit/c.txt"))
            guard let second = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "tree: no second version"
            }
            let firstBody = try manifestObject(vault, first.id)
            let secondBody = try manifestObject(vault, second.id)
            if firstBody["files"] != nil || secondBody["files"] != nil {
                return "tree: a version stored every file"
            }
            guard let firstRoot = firstBody["tree"] as? String, let secondRoot = secondBody["tree"] as? String else {
                return "tree: a version has no directory record"
            }
            if firstRoot == secondRoot { return "tree: an edit left the root unchanged" }
            let firstKeep = try directoryHash(vault, firstRoot, "keep")
            let secondKeep = try directoryHash(vault, secondRoot, "keep")
            if firstKeep == nil || firstKeep != secondKeep {
                return "tree: the unchanged directory was stored again"
            }
            let firstEdit = try directoryHash(vault, firstRoot, "edit")
            let secondEdit = try directoryHash(vault, secondRoot, "edit")
            if firstEdit == nil || firstEdit == secondEdit {
                return "tree: the edited directory kept its old record"
            }
            let bodyURL = vault.appendingPathComponent("snapshots").appendingPathComponent(second.id + ".json")
            let bodySize = try Data(contentsOf: bodyURL).count
            if bodySize > 2_500 {
                return "tree: the version file is \(bodySize) bytes"
            }
            if try Vault.load(vault, second.id).files.count != second.files.count {
                return "tree: loading the version dropped a file"
            }
            let dest = root.appendingPathComponent("restored")
            try Vault.restore(vault: vault, snapshot: second.id, dest: dest, allowInsideSource: false)
            if try Data(contentsOf: dest.appendingPathComponent("edit/c.txt")) != Data("changed".utf8) {
                return "tree: restore did not return the edit"
            }
            if try Data(contentsOf: dest.appendingPathComponent("keep/a.txt")) != Data("aaa".utf8) {
                return "tree: restore did not return the unchanged file"
            }
            return nil
        } catch {
            return "tree: \(error.localizedDescription)"
        }
    }

    /// A version written with an inline file list still restores after its directory records are gone.
    private static func testInlineManifestStillRestores() -> String? {
        let root = temp("inline")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: source.appendingPathComponent("note.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "inline: no version"
            }
            var inline = snap
            inline.tree = nil
            try JSONFile.write(inline, to: vault.appendingPathComponent("snapshots").appendingPathComponent(snap.id + ".json"), pretty: false)
            try? FileManager.default.removeItem(at: vault.appendingPathComponent("trees"))
            let dest = root.appendingPathComponent("restored")
            try Vault.restore(vault: vault, snapshot: snap.id, dest: dest, allowInsideSource: false)
            if try Data(contentsOf: dest.appendingPathComponent("note.txt")) != Data("kept".utf8) {
                return "inline: the older version did not restore"
            }
            let report = try Vault.verifyHistory(vault: vault)
            if !report.problems.isEmpty { return "inline: \(report.summary)" }
            return nil
        } catch {
            return "inline: \(error.localizedDescription)"
        }
    }

    private static func testRetentionThinsOldVersions() -> String? {
        let now = utcDate(year: 2026, month: 11, day: 21, hour: 12, minute: 30, second: 0)
        let ids = [
            "20261121-110000-aaaaaaa1",
            "20261121-100000-aaaaaaa2",
            "20261121-100500-aaaaaaa3",
            "20261120-124000-aaaaaaa4",
            "20261120-120000-aaaaaaa5",
            "20261120-121500-aaaaaaa6",
            "20261119-150000-aaaaaaa7",
            "20261119-150015-aaaaaaa8",
            "20261119-160000-aaaaaaa9",
            "20261023-120000-aaaaaaab",
            "20261023-120100-aaaaaaac",
            "20261022-130000-aaaaaaad",
            "20261022-120000-aaaaaaae",
            "20261022-123000-aaaaaaaf",
            "20261001-120000-aaaaaaa0",
            "20261001-180000-aaaaaaa1",
            "20261002-010000-aaaaaaa2",
            "not-a-version",
        ]
        let kept = Vault.Retention.keep(ids, now: now)
        let dropped: Set<String> = [
            "20261120-121500-aaaaaaa6",
            "20261119-150015-aaaaaaa8",
            "20261023-120100-aaaaaaac",
            "20261022-123000-aaaaaaaf",
            "20261001-180000-aaaaaaa1",
        ]
        for id in dropped where kept.contains(id) {
            return "retention: \(id) was kept"
        }
        let wanted: Set<String> = [
            "20261121-110000-aaaaaaa1",
            "20261121-100000-aaaaaaa2",
            "20261121-100500-aaaaaaa3",
            "20261120-124000-aaaaaaa4",
            "20261120-120000-aaaaaaa5",
            "20261119-150000-aaaaaaa7",
            "20261119-160000-aaaaaaa9",
            "20261023-120000-aaaaaaab",
            "20261022-130000-aaaaaaad",
            "20261022-120000-aaaaaaae",
            "20261001-120000-aaaaaaa0",
            "20261002-010000-aaaaaaa2",
            "not-a-version",
        ]
        if kept != wanted { return "retention: kept \(kept.sorted())" }

        let root = temp("thin")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("note".utf8).write(to: source.appendingPathComponent("note.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "retention: no version"
            }
            guard let hash = snap.files.first(where: { $0.path == "note.txt" })?.chunks.first else {
                return "retention: no chunk"
            }
            let old = "20261001-120000-bbbbbbb1"
            let extra = "20261001-180000-bbbbbbb2"
            try copyManifest(vault, from: snap.id, to: old, created: "2026-10-01T12:00:00.000Z")
            try copyManifest(vault, from: snap.id, to: extra, created: "2026-10-01T18:00:00.000Z")
            let orphan = chunkFile(vault, String(repeating: "ab", count: 32))
            try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("orphan".utf8).write(to: orphan)
            let removed = try Vault.prune(vault: vault, now: now)
            if removed.count != 1 { return "retention: removed \(removed.count)" }
            if removed.removed.map(\.id) != [extra] {
                return "retention: dropped \(removed.removed.map(\.id))"
            }
            if removed.freed != 6 || !removed.complete {
                return "retention: freed \(removed.freed) complete \(removed.complete)"
            }
            let told = ThinText.sentence(names: ThinText.names(removed), freed: removed.freed, complete: removed.complete)
            if !told.hasPrefix("Removed ") || !told.contains("Freed 6 B.") {
                return "retention: the note was \(told)"
            }
            let left = Set(try Vault.listHeads(vault).map(\.id))
            if !left.contains(snap.id) || !left.contains(old) || left.contains(extra) {
                return "retention: versions were \(left.sorted())"
            }
            if FileManager.default.fileExists(atPath: orphan.path) {
                return "retention: an unused chunk stayed"
            }
            if !FileManager.default.fileExists(atPath: chunkFile(vault, hash).path) {
                return "retention: a chunk still in use was removed"
            }
            let dest = root.appendingPathComponent("restored")
            try Vault.restore(vault: vault, snapshot: old, dest: dest, allowInsideSource: false)
            if try Data(contentsOf: dest.appendingPathComponent("note.txt")) != Data("note".utf8) {
                return "retention: the kept day did not restore"
            }
            return nil
        } catch {
            return "retention: \(error.localizedDescription)"
        }
    }

    /// A label or a manual snapshot stays, and does not take the hour or day of an unlabeled one.
    /// A head that cannot be read stays. An unlabeled body that cannot be read is still thinned.
    private static func testLabeledVersionsStay() -> String? {
        let now = utcDate(year: 2026, month: 11, day: 21, hour: 12, minute: 30, second: 0)
        let pins = [
            Vault.Retention.Pin(id: "20261001-120000-aaaaaaa0"),
            Vault.Retention.Pin(id: "20261001-180000-aaaaaaa1", label: "before the big refactor"),
            Vault.Retention.Pin(id: "20261120-120000-aaaaaaa5"),
            Vault.Retention.Pin(id: "20261120-121500-aaaaaaa6", reason: "manual"),
            Vault.Retention.Pin(id: "20261022-120000-aaaaaaae", reason: "cli"),
            Vault.Retention.Pin(id: "20261022-123000-aaaaaaaf", label: "   ", reason: "cli"),
            Vault.Retention.Pin(id: "20261023-120000-aaaaaaab"),
            Vault.Retention.Pin(id: "20261023-120100-aaaaaaac", protect: true),
        ]
        let kept = Vault.Retention.keep(pins, now: now)
        let wanted: Set<String> = [
            "20261001-120000-aaaaaaa0",
            "20261001-180000-aaaaaaa1",
            "20261120-120000-aaaaaaa5",
            "20261120-121500-aaaaaaa6",
            "20261022-120000-aaaaaaae",
            "20261023-120000-aaaaaaab",
            "20261023-120100-aaaaaaac",
        ]
        if kept != wanted { return "pin: kept \(kept.sorted())" }

        let root = temp("pin")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        let hidden = "20261001-180000-bbbbbbb5"
        let extra = "20261001-150000-bbbbbbb2"
        let extraURL = vault.appendingPathComponent("snapshots").appendingPathComponent(extra + ".json")
        let hiddenHead = vault.appendingPathComponent("snapshots").appendingPathComponent(hidden + ".head.json")
        let hiddenBody = vault.appendingPathComponent("snapshots").appendingPathComponent(hidden + ".json")
        defer {
            _ = chmod(extraURL.path, 0o644)
            _ = chmod(hiddenHead.path, 0o644)
        }
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("note".utf8).write(to: source.appendingPathComponent("note.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "pin: no version"
            }
            let old = "20261001-120000-bbbbbbb1"
            let labeled = "20261001-160000-bbbbbbb3"
            let manual = "20261001-170000-bbbbbbb4"
            try copyManifest(vault, from: snap.id, to: old, created: "2026-10-01T12:00:00.000Z")
            try copyManifest(vault, from: snap.id, to: extra, created: "2026-10-01T15:00:00.000Z")
            try copyManifest(vault, from: snap.id, to: labeled, created: "2026-10-01T16:00:00.000Z", label: "before the big refactor")
            try copyManifest(vault, from: snap.id, to: manual, created: "2026-10-01T17:00:00.000Z", reason: "manual")
            try copyManifest(vault, from: snap.id, to: hidden, created: "2026-10-01T18:00:00.000Z")
            if chmod(extraURL.path, 0o000) != 0 { return "pin: could not hide a version body" }
            if chmod(hiddenHead.path, 0o000) != 0 { return "pin: could not hide a head" }
            let removed = try Vault.prune(vault: vault, now: now)
            if removed.count != 1 || removed.removed.first?.id != extra {
                return "pin: removed \(removed.removed.map(\.id))"
            }
            _ = chmod(hiddenHead.path, 0o644)
            let left = Set(try Vault.listHeads(vault).map(\.id))
            for id in [snap.id, old, labeled, manual, hidden] where !left.contains(id) {
                return "pin: \(id) was dropped from \(left.sorted())"
            }
            if left.contains(extra) { return "pin: an unlabeled copy was kept" }
            if try Vault.load(vault, labeled).label != "before the big refactor" {
                return "pin: the label was lost"
            }
            if !FileManager.default.fileExists(atPath: hiddenBody.path) {
                return "pin: an unreadable head was deleted"
            }
            return nil
        } catch {
            return "pin: \(error.localizedDescription)"
        }
    }

    /// Thinning deletes the recorded parent. The comparison uses the newest version that is still there.
    private static func testMissingParentUsesTheSurvivingVersion() -> String? {
        let root = temp("compare")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("alpha".utf8).write(to: source.appendingPathComponent("a.txt"))
            guard let first = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "compare: no first version"
            }
            Thread.sleep(forTimeInterval: 1.1)
            try Data("bravo".utf8).write(to: source.appendingPathComponent("b.txt"))
            guard let second = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "compare: no second version"
            }
            Thread.sleep(forTimeInterval: 1.1)
            guard let third = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "compare: an unchanged folder was dropped"
            }
            if !(first.id < second.id && second.id < third.id) {
                return "compare: ids were \(first.id) \(second.id) \(third.id)"
            }
            if third.parent != second.id { return "compare: parent was \(third.parent ?? "missing")" }
            if third.stats.newChunkBytes != 0 { return "compare: stored \(third.stats.newChunkBytes) new bytes" }
            let recorded = Vault.glance(vault: vault, snap: try Vault.load(vault, third.id))
            if !recorded.quiet || recorded.newBytes != 0 {
                return "compare: the recorded parent was replaced"
            }
            let directory = vault.appendingPathComponent("snapshots")
            let parentBody = directory.appendingPathComponent(second.id + ".json")
            let savedParent = try Data(contentsOf: parentBody)
            try Data("{".utf8).write(to: parentBody)
            let whilePresent = Vault.rowGlances(vault: vault, heads: [third.head])
            if whilePresent[third.id] != VersionGlance(newBytes: 0, quiet: true) {
                return "compare: a parent file that is still there was remeasured"
            }
            try savedParent.write(to: parentBody)
            try FileManager.default.removeItem(at: parentBody)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(second.id + ".head.json"))
            // Listing can fail while a known version file still opens. That is not "every parent is missing".
            if chmod(directory.path, 0o311) != 0 { return "compare: could not hide the version list" }
            defer { _ = chmod(directory.path, 0o755) }
            let duringBlip = Vault.rowGlances(vault: vault, heads: [third.head])
            if duringBlip[third.id] != VersionGlance(newBytes: 0, quiet: true) {
                return "compare: a directory read treated every parent as missing"
            }
            if chmod(directory.path, 0o755) != 0 { return "compare: could not show the version list" }
            let snap = try Vault.load(vault, third.id)
            let basis = Vault.compared(vault: vault, to: snap)
            if !basis.substituted || basis.parent?.id != first.id {
                return "compare: predecessor was \(basis.parent?.id ?? "missing")"
            }
            let rows = Diff.rows(current: snap.files, parent: basis.parent?.files, comparable: basis.comparable)
            guard let added = rows.first(where: { $0.path == "b.txt" }), added.change == "added" else {
                return "compare: b.txt was \(rows.first { $0.path == "b.txt" }?.change ?? "missing")"
            }
            let glance = Diff.measure(snap: snap, parent: basis.parent, substituted: basis.substituted)
            if glance.quiet { return "compare: a missing parent still said nothing new" }
            if glance.newBytes != Int64("bravo".utf8.count) || added.newBytes != glance.newBytes {
                return "compare: new bytes were \(glance.newBytes) and the row said \(added.newBytes)"
            }
            if snap.stats.newChunkBytes != 0 { return "compare: the stored count was rewritten" }
            let measured = Vault.rowGlances(vault: vault, heads: [third.head])
            if measured[third.id] != glance {
                return "compare: the version list kept the stored count"
            }
            try FileManager.default.removeItem(at: directory.appendingPathComponent(first.id + ".json"))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(first.id + ".head.json"))
            let cached = Vault.rowGlances(vault: vault, heads: [third.head])
            if cached[third.id] != glance {
                return "compare: a saved measurement was redone"
            }
            let none = Vault.compared(vault: vault, to: try Vault.load(vault, third.id))
            if none.comparable || none.substituted { return "compare: a missing history still compared" }
            let waiting = Diff.rows(current: snap.files, parent: none.parent?.files, comparable: none.comparable)
            if waiting.first(where: { $0.path == "b.txt" })?.change != "same" {
                return "compare: the wait was \(waiting.first { $0.path == "b.txt" }?.change ?? "missing")"
            }
            return nil
        } catch {
            return "compare: \(error.localizedDescription)"
        }
    }

    /// A symlink to a folder is stored, not followed, and must not hide the next real folder.
    private static func testSymlinkDoesNotHideTheNextFolder() -> String? {
        let root = temp("skip-link")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let before = source.appendingPathComponent("before")
            try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
            try Data("earlier".utf8).write(to: before.appendingPathComponent("kept.txt"))
            let hold = root.appendingPathComponent("hold")
            try FileManager.default.createDirectory(at: hold, withIntermediateDirectories: true)
            try Data("inside".utf8).write(to: hold.appendingPathComponent("inside.txt"))
            try FileManager.default.createSymbolicLink(
                atPath: source.appendingPathComponent("linkdir").path,
                withDestinationPath: hold.path
            )
            var markers = ["before/kept.txt"]
            if !aDirectoryFollows(source, "linkdir") {
                // Directory order is not creation order. Try names until one is visited after the symlink.
                for name in ["later", "after", "zzz", "m", "hold", "mlink", "post", "tail"] {
                    let dir = source.appendingPathComponent(name)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try Data("later".utf8).write(to: dir.appendingPathComponent("kept.txt"))
                    markers.append("\(name)/kept.txt")
                    if aDirectoryFollows(source, "linkdir") { break }
                }
            } else {
                let dir = source.appendingPathComponent("later")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data("later".utf8).write(to: dir.appendingPathComponent("kept.txt"))
                markers.append("later/kept.txt")
            }
            if !aDirectoryFollows(source, "linkdir") {
                return "skip: a folder never followed the symlink"
            }
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "skip: snapshot was empty"
            }
            let paths = Set(snap.files.map(\.path))
            for path in markers where !paths.contains(path) {
                return "skip: \(path) was hidden from \(paths.sorted())"
            }
            if snap.files.first(where: { $0.path == "linkdir" })?.kind != "link" {
                return "skip: the symlink was stored as a folder"
            }
            if paths.contains("linkdir/inside.txt") { return "skip: the symlink was followed" }
            return nil
        } catch {
            return "skip: \(error.localizedDescription)"
        }
    }

    private static func aDirectoryFollows(_ root: URL, _ name: String) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return false }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        var seen = false
        while let url = enumerator.nextObject() as? URL {
            if !seen {
                let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                if url.lastPathComponent == name, parent == rootPath {
                    seen = true
                }
                continue
            }
            var info = stat()
            if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
                return true
            }
        }
        return false
    }

    private static func testMissingDirectoryRecordIsNamed() -> String? {
        let root = temp("missing-tree")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("note".utf8).write(to: source.appendingPathComponent("note.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "directory: no version"
            }
            guard let hash = snap.tree else { return "directory: no record" }
            guard let chunk = snap.files.first(where: { $0.path == "note.txt" })?.chunks.first else {
                return "directory: no chunk"
            }
            let record = vault.appendingPathComponent("trees").appendingPathComponent(String(hash.prefix(2))).appendingPathComponent(hash)
            try FileManager.default.removeItem(at: record)
            let report = try Vault.verifyHistory(vault: vault)
            if report.summary != "1 damaged or missing directory affects 1 version." {
                return "directory: summary was \(report.summary)"
            }
            if !report.detail.contains("Missing directory \(hash.prefix(12))") {
                return "directory: detail was \(report.detail)"
            }
            do {
                _ = try Vault.clean(vault)
                return "directory: cleanup deleted records while one was missing"
            } catch {
                if error.localizedDescription != "A version could not be read, so unused chunks were left in place." {
                    return "directory: \(error.localizedDescription)"
                }
            }
            if !FileManager.default.fileExists(atPath: chunkFile(vault, chunk).path) {
                return "directory: the missing record took a chunk with it"
            }
            return nil
        } catch {
            return "directory: \(error.localizedDescription)"
        }
    }

    private static func manifestObject(_ vault: URL, _ id: String) throws -> [String: Any] {
        let url = vault.appendingPathComponent("snapshots").appendingPathComponent(id + ".json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return object as? [String: Any] ?? [:]
    }

    private static func directoryHash(_ vault: URL, _ root: String, _ name: String) throws -> String? {
        let url = vault.appendingPathComponent("trees").appendingPathComponent(String(root.prefix(2))).appendingPathComponent(root)
        let plain = try ChunkCodec.decode(Data(contentsOf: url), max: 32 * 1024 * 1024)
        let nodes = try JSONSerialization.jsonObject(with: plain) as? [[String: Any]] ?? []
        return nodes.first { $0["name"] as? String == name }?["tree"] as? String
    }

    private static func copyManifest(
        _ vault: URL,
        from source: String,
        to id: String,
        created: String,
        label: String = "",
        reason: String = "watch"
    ) throws {
        let directory = vault.appendingPathComponent("snapshots")
        var object = try manifestObject(vault, source)
        object["id"] = id
        object["created"] = created
        object["parent"] = NSNull()
        object["label"] = label
        object["reason"] = reason
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: directory.appendingPathComponent(id + ".json"))
        let head = directory.appendingPathComponent(source + ".head.json")
        if FileManager.default.fileExists(atPath: head.path) {
            var index = try JSONSerialization.jsonObject(with: Data(contentsOf: head)) as? [String: Any] ?? [:]
            index["id"] = id
            index["created"] = created
            index["parent"] = NSNull()
            index["label"] = label
            index["reason"] = reason
            let copied = try JSONSerialization.data(withJSONObject: index)
            try copied.write(to: directory.appendingPathComponent(id + ".head.json"))
        }
    }

    private static func utcDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Date {
        var parts = DateComponents()
        parts.calendar = Calendar(identifier: .gregorian)
        parts.timeZone = TimeZone(secondsFromGMT: 0)
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        parts.second = second
        return parts.date ?? Date()
    }

    private static func lstatInfoKind(_ url: URL) -> String? {
        var info = stat()
        if lstat(url.path, &info) != 0 { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return "dir"
        case S_IFREG: return "file"
        case S_IFLNK: return "link"
        default: return "other"
        }
    }

    /// The newest day stays open. Earlier days are separate rows and start collapsed.
    private static func testVersionDaysGroupPreviousDays() -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var parts = DateComponents()
        parts.calendar = calendar
        parts.timeZone = calendar.timeZone
        parts.year = 2026
        parts.month = 11
        parts.day = 21
        parts.hour = 15
        guard let now = calendar.date(from: parts) else { return "days: no clock" }
        let alone = VersionDays.group(
            [versionHead("2026-11-21T14:00:00.000Z", "20261121-140000-aaaaaaaa")],
            now: now,
            calendar: calendar
        )
        if alone.count != 1 || !alone[0].opensFlat || alone[0].showsHeader || alone[0].title != "Today" {
            return "days: one day was \(alone.map { "\($0.title) flat=\($0.opensFlat) header=\($0.showsHeader)" })"
        }
        let heads = [
            versionHead("2026-11-21T14:00:00.000Z", "20261121-140000-aaaaaaaa"),
            versionHead("2026-11-21T09:00:00.000Z", "20261121-090000-aaaaaaab"),
            versionHead("2026-11-20T18:00:00.000Z", "20261120-180000-aaaaaaac"),
            versionHead("2026-11-18T12:00:00.000Z", "20261118-120000-aaaaaaad"),
            versionHead("nope", "20261119-080000-aaaaaaae"),
            versionHead("still-nope", "not-an-id"),
        ]
        let days = VersionDays.group(heads, now: now, calendar: calendar)
        if days.map(\.id) != ["2026-11-21", "2026-11-20", "2026-11-19", "2026-11-18", "other"] {
            return "days: order was \(days.map(\.id))"
        }
        if days.map(\.title) != ["Today", "Yesterday", days[2].title, days[3].title, "Other"] {
            return "days: titles were \(days.map(\.title))"
        }
        if !days[2].title.contains("19") || !days[2].title.contains("2026") {
            return "days: an older day was titled \(days[2].title)"
        }
        if !days[3].title.contains("18") || !days[3].title.contains("2026") {
            return "days: the oldest day was titled \(days[3].title)"
        }
        if !days[0].opensFlat || days[0].heads.map(\.id) != ["20261121-140000-aaaaaaaa", "20261121-090000-aaaaaaab"] {
            return "days: today did not stay open in order"
        }
        if days.dropFirst().contains(where: \.opensFlat) {
            return "days: an earlier day stayed open"
        }
        if days.contains(where: { !$0.showsHeader }) {
            return "days: a divided list hid its day title"
        }
        if days[4].heads.map(\.id) != ["not-an-id"] {
            return "days: an undated version was \(days[4].heads.map(\.id))"
        }
        return nil
    }

    /// Thinning names the versions it removed and says whether that freed any unique bytes.
    private static func testThinningSaysWhatItRemoved() -> String? {
        func line(_ names: [String], _ freed: Int64, _ complete: Bool = true) -> String {
            ThinText.sentence(names: names, freed: freed, complete: complete)
        }
        let one = line(["Nov 1"], 6)
        if one != "Removed Nov 1. Freed 6 B." { return "thin-note: one was \(one)" }
        let shared = line(["Nov 1"], 0)
        if shared != "Removed Nov 1. Freed nothing. The kept versions still use those bytes." {
            return "thin-note: shared bytes were \(shared)"
        }
        let pair = line(["Nov 1", "Nov 2"], 12)
        if pair != "Removed Nov 1 and Nov 2. Freed 12 B." { return "thin-note: two were \(pair)" }
        let three = line(["Nov 1", "Nov 2", "Nov 3"], 10)
        if three != "Removed Nov 1, Nov 2, and Nov 3. Freed 10 B." { return "thin-note: three were \(three)" }
        let four = line(["A", "B", "C", "D"], 1)
        if four != "Removed A, B, C, and D. Freed 1 B." { return "thin-note: four were \(four)" }
        let span = line(["A", "B", "C", "D", "E"], 0)
        if span != "Removed 5 older versions, from A through E. Freed nothing. The kept versions still use those bytes." {
            return "thin-note: a long list was \(span)"
        }
        let blocked = line(["Nov 1"], 6, false)
        if blocked != "Removed Nov 1. A version could not be read, so unused chunks were left in place." {
            return "thin-note: an unfinished pass was \(blocked)"
        }
        if blocked.contains("Freed") { return "thin-note: an unfinished pass claimed space" }
        let blank = line([], 4)
        if blank != "Removed older versions. Freed 4 B." { return "thin-note: unnamed versions were \(blank)" }

        let unnamed = PruneResult(
            removed: [PrunedVersion(id: "20261001-120000-aaaaaaaa", created: nil)],
            freed: 0,
            complete: true
        )
        if ThinText.names(unnamed) != ["an older version"] {
            return "thin-note: a missing time was \(ThinText.names(unnamed))"
        }
        let quiet = ThinText.report([("Notes", .none)], nameEach: true)
        if !quiet.isEmpty { return "thin-note: an empty pass said \(quiet)" }
        let alone = ThinText.report([("Notes", unnamed)], nameEach: false)
        if alone != "Removed an older version. Freed nothing. The kept versions still use those bytes." {
            return "thin-note: one folder was \(alone)"
        }
        if alone.contains("Notes:") { return "thin-note: one folder was named twice" }
        let folders = ThinText.report([
            ("Notes", unnamed),
            ("Quiet", .none),
            ("Photos", PruneResult(
                removed: [
                    PrunedVersion(id: "20261001-120000-aaaaaaa1", created: nil),
                    PrunedVersion(id: "20261002-120000-aaaaaaa2", created: nil),
                ],
                freed: 6,
                complete: true
            )),
        ], nameEach: true)
        let wanted = "Notes: Removed an older version. Freed nothing. The kept versions still use those bytes. Photos: Removed an older version and an older version. Freed 6 B."
        if folders != wanted { return "thin-note: folders were \(folders)" }

        let now = utcDate(year: 2026, month: 11, day: 21, hour: 12, minute: 30, second: 0)
        let root = temp("thin-note")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("note".utf8).write(to: source.appendingPathComponent("note.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "thin-note: no version"
            }
            let firstID = "20261001-180000-bbbbbbb2"
            let secondID = "20261002-180000-bbbbbbb3"
            try copyManifest(vault, from: snap.id, to: "20261001-120000-bbbbbbb1", created: "2026-10-01T12:00:00.000Z")
            try copyManifest(vault, from: snap.id, to: firstID, created: "2026-10-01T18:00:00.000Z")
            try copyManifest(vault, from: snap.id, to: "20261002-120000-bbbbbbb4", created: "2026-10-02T12:00:00.000Z")
            try copyManifest(vault, from: snap.id, to: secondID, created: "2026-10-02T18:00:00.000Z")
            let orphan = chunkFile(vault, String(repeating: "cd", count: 32))
            try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("orphan".utf8).write(to: orphan)
            let removed = try Vault.prune(vault: vault, now: now)
            if removed.removed.map(\.id) != [firstID, secondID] {
                return "thin-note: dropped \(removed.removed.map(\.id))"
            }
            if removed.freed != 6 || !removed.complete {
                return "thin-note: freed \(removed.freed) complete \(removed.complete)"
            }
            guard let firstDate = TimeText.parse("2026-10-01T18:00:00.000Z"),
                  let secondDate = TimeText.parse("2026-10-02T18:00:00.000Z") else {
                return "thin-note: a removed time did not parse"
            }
            let names = [TimeText.display(firstDate), TimeText.display(secondDate)]
            if ThinText.names(removed) != names {
                return "thin-note: names were \(ThinText.names(removed))"
            }
            let told = ThinText.sentence(names: names, freed: removed.freed, complete: removed.complete)
            if told != "Removed \(names[0]) and \(names[1]). Freed 6 B." {
                return "thin-note: the history said \(told)"
            }
            if FileManager.default.fileExists(atPath: orphan.path) {
                return "thin-note: an unused chunk stayed"
            }
            return nil
        } catch {
            return "thin-note: \(error.localizedDescription)"
        }
    }

    /// Each folder records the passes that removed versions, and a total from the first of those passes.
    private static func testThinningHistoryTotalsSinceLoggingBegan() -> String? {
        let when = utcDate(year: 2026, month: 11, day: 21, hour: 12, minute: 30, second: 0)
        var log = ThinningLog.empty
        if log.recording(.none, at: when) != log { return "thin-log: an empty pass was stored" }
        let kept = PruneResult(
            removed: [PrunedVersion(id: "20261001-180000-bbbbbbb2", created: when)],
            freed: 6,
            complete: true
        )
        log = log.recording(kept, at: when)
        if log.removed != 1 || log.freed != 6 || log.passes.count != 1 || log.since != TimeText.nowISO(when) {
            return "thin-log: the first pass was \(log.removed) \(log.freed) \(log.since)"
        }
        let blocked = PruneResult(
            removed: [PrunedVersion(id: "20261002-180000-bbbbbbb3", created: nil)],
            freed: 50,
            complete: false
        )
        log = log.recording(blocked, at: when.addingTimeInterval(60))
        if log.removed != 2 || log.freed != 6 || log.passes.first?.freed != 0 || log.passes.first?.complete != false {
            return "thin-log: an unfinished pass changed the total to \(log.freed)"
        }
        if log.since != TimeText.nowISO(when) { return "thin-log: logging began again" }
        if ThinText.names(log.passes[0]) != ["an older version"] {
            return "thin-log: a missing time was \(ThinText.names(log.passes[0]))"
        }
        let one = ThinningText.total(ThinningLog(since: TimeText.nowISO(when), removed: 1, freed: 6, passes: []))
        if one != "\(TimeText.day(when)) · 1 version · Freed 6 B" {
            return "thin-log: one version totaled \(one)"
        }
        let none = ThinningText.total(ThinningLog(since: "", removed: 2, freed: 0, passes: []))
        if none != "2 versions · Freed nothing" { return "thin-log: a shared total was \(none)" }

        var capped = ThinningLog.empty
        let start = utcDate(year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 0)
        let extra = ThinningLog.keptPasses + 1
        for index in 0..<extra {
            let at = start.addingTimeInterval(TimeInterval(index))
            let id = String(format: "20260101-000000-%08x", index)
            capped = capped.recording(
                PruneResult(removed: [PrunedVersion(id: id, created: at)], freed: 2, complete: true),
                at: at
            )
        }
        if capped.passes.count != ThinningLog.keptPasses || capped.removed != extra || capped.freed != Int64(extra * 2) {
            return "thin-log: the capped total was \(capped.passes.count) \(capped.removed) \(capped.freed)"
        }
        if capped.since != TimeText.nowISO(start) { return "thin-log: the first day was \(capped.since)" }
        let oldest = String(format: "20260101-000000-%08x", 0)
        let newest = String(format: "20260101-000000-%08x", extra - 1)
        if capped.passes.contains(where: { $0.versions.contains { $0.id == oldest } }) {
            return "thin-log: the oldest pass stayed in the list"
        }
        if capped.passes.first?.versions.first?.id != newest {
            return "thin-log: the newest pass was \(capped.passes.first?.versions.first?.id ?? "missing")"
        }

        let blank = temp("thin-log-blank")
        defer { try? FileManager.default.removeItem(at: blank) }
        let untouched = Vault.thinningHistory(blank)
        if !untouched.readable || untouched.log.removed != 0 { return "thin-log: a new folder already had a total" }

        let now = when
        let root = temp("thin-log")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        let moved = root.appendingPathComponent("moved")
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("note".utf8).write(to: source.appendingPathComponent("note.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "thin-log: no version"
            }
            let firstID = "20261001-180000-bbbbbbb2"
            let secondID = "20261002-180000-bbbbbbb3"
            let thirdID = "20261003-180000-bbbbbbb4"
            try copyManifest(vault, from: snap.id, to: "20261001-120000-bbbbbbb1", created: "2026-10-01T12:00:00.000Z")
            try copyManifest(vault, from: snap.id, to: firstID, created: "2026-10-01T18:00:00.000Z")
            let orphan = chunkFile(vault, String(repeating: "ef", count: 32))
            try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("orphan".utf8).write(to: orphan)
            _ = try Vault.prune(vault: vault, now: now)
            var history = Vault.thinningHistory(vault)
            if !history.readable || history.log.removed != 1 || history.log.freed != 6 || history.log.passes.count != 1 {
                return "thin-log: the file was \(history.readable) \(history.log.removed) \(history.log.freed)"
            }
            if history.log.passes[0].versions.map(\.id) != [firstID] {
                return "thin-log: logged \(history.log.passes[0].versions.map(\.id))"
            }
            if history.log.since != TimeText.nowISO(now) { return "thin-log: since was \(history.log.since)" }
            guard let created = history.log.passes[0].versions[0].created,
                  let parsed = TimeText.parse(created),
                  let expected = TimeText.parse("2026-10-01T18:00:00.000Z"),
                  parsed == expected else {
                return "thin-log: the removed time was \(history.log.passes[0].versions[0].created ?? "missing")"
            }
            _ = try Vault.prune(vault: vault, now: now)
            if Vault.thinningHistory(vault).log.passes.count != 1 { return "thin-log: a quiet pass was stored" }

            try copyManifest(vault, from: snap.id, to: "20261002-120000-bbbbbbb5", created: "2026-10-02T12:00:00.000Z")
            try copyManifest(vault, from: snap.id, to: secondID, created: "2026-10-02T18:00:00.000Z")
            let more = chunkFile(vault, String(repeating: "ab", count: 32))
            try FileManager.default.createDirectory(at: more.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("abcd".utf8).write(to: more)
            _ = try Vault.prune(vault: vault, now: now.addingTimeInterval(60))
            history = Vault.thinningHistory(vault)
            if history.log.removed != 2 || history.log.freed != 10 || history.log.passes.count != 2 {
                return "thin-log: two passes were \(history.log.removed) \(history.log.freed) \(history.log.passes.count)"
            }
            if history.log.passes[0].versions.map(\.id) != [secondID] || history.log.since != TimeText.nowISO(now) {
                return "thin-log: the newer pass was \(history.log.passes[0].versions.map(\.id))"
            }
            let saved = try Data(contentsOf: vault.appendingPathComponent("thinning.json"))
            try Data("{".utf8).write(to: vault.appendingPathComponent("thinning.json"))
            if Vault.thinningHistory(vault).readable { return "thin-log: a broken file was treated as empty" }
            try copyManifest(vault, from: snap.id, to: "20261003-120000-bbbbbbb6", created: "2026-10-03T12:00:00.000Z")
            try copyManifest(vault, from: snap.id, to: thirdID, created: "2026-10-03T18:00:00.000Z")
            _ = try Vault.prune(vault: vault, now: now)
            let broken = try Data(contentsOf: vault.appendingPathComponent("thinning.json"))
            if broken != Data("{".utf8) { return "thin-log: a broken file was replaced" }
            if try Vault.listHeads(vault).contains(where: { $0.id == thirdID }) {
                return "thin-log: a broken file kept the version"
            }
            try saved.write(to: vault.appendingPathComponent("thinning.json"))
            history = Vault.thinningHistory(vault)
            if history.log.removed != 2 || history.log.freed != 10 { return "thin-log: restoring the file changed the total" }
            try Vault.relocate(from: vault, to: moved)
            if FileManager.default.fileExists(atPath: vault.path) { return "thin-log: the old history stayed" }
            let carried = Vault.thinningHistory(moved)
            if !carried.readable || carried.log.removed != 2 || carried.log.freed != 10 || carried.log.passes.count != 2 {
                return "thin-log: the move kept \(carried.log.removed) \(carried.log.freed)"
            }
            return nil
        } catch {
            return "thin-log: \(error.localizedDescription)"
        }
    }

    private static func versionHead(_ created: String, _ id: String) -> SnapshotHead {
        SnapshotHead(
            format: AppInfo.format,
            id: id,
            parent: nil,
            created: created,
            label: "",
            reason: "watch",
            source: "/tmp",
            stats: SnapshotStats()
        )
    }

    private static func hashes(_ data: Data) -> [UInt64] {
        var state = BuzState(window: 32)
        var out: [UInt64] = []
        out.reserveCapacity(data.count)
        for byte in data {
            state.feed(byte)
            out.append(state.hash)
        }
        return out
    }

    /// Opening a tree-format version lists the same rows as the expanded diff, without requiring that expansion to build them.
    private static func testStreamingBrowseMatchesTheDiff() -> String? {
        let root = temp("browse")
        let secret = root.appendingPathComponent("source/secret.txt")
        defer {
            _ = chmod(secret.path, 0o644)
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: source.appendingPathComponent("stay"), withIntermediateDirectories: true)
            try Data("same".utf8).write(to: source.appendingPathComponent("same.txt"))
            try Data("edit".utf8).write(to: source.appendingPathComponent("edit.txt"))
            try Data("gone".utf8).write(to: source.appendingPathComponent("gone.txt"))
            try Data("secret".utf8).write(to: secret)
            try Data("stay".utf8).write(to: source.appendingPathComponent("stay/keep.txt"))
            guard try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) != nil else {
                return "browse: first snapshot was empty"
            }
            try Data("edited".utf8).write(to: source.appendingPathComponent("edit.txt"))
            try FileManager.default.removeItem(at: source.appendingPathComponent("gone.txt"))
            try FileManager.default.createDirectory(at: source.appendingPathComponent("added"), withIntermediateDirectories: true)
            try Data("secret two".utf8).write(to: secret)
            if chmod(secret.path, 0) != 0 { return "browse: could not hide secret.txt" }
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "browse: second snapshot was empty"
            }
            let loaded = try Vault.load(vault, snap.id)
            let basis = Vault.compared(vault: vault, to: loaded)
            let warnings = loaded.warnings(skipNames: Set(VaultConfig.defaultSkip))
            let expected = Diff.rows(
                current: loaded.files,
                parent: basis.parent?.files,
                comparable: basis.comparable,
                carried: warnings.carried,
                unread: warnings.unread
            )
            let listed = try Vault.listVersion(vault, snap.id)
            if listed.rows != expected {
                return "browse: rows were \(listed.rows) expected \(expected)"
            }
            let folders = loaded.files.compactMap { $0.kind == "dir" ? $0.path : nil }.sorted()
            if listed.folders != folders {
                return "browse: folders were \(listed.folders) expected \(folders)"
            }
            if !listed.rows.contains(where: { $0.path == "same.txt" && $0.change == "same" }) {
                return "browse: an unchanged file was dropped"
            }
            if !listed.rows.contains(where: { $0.path == "gone.txt" && $0.change == "removed" }) {
                return "browse: a removed file was dropped"
            }
            if !listed.rows.contains(where: { $0.path == "secret.txt" && $0.change == "carried" }) {
                return "browse: a carried file was dropped"
            }
            if listed.rows.contains(where: { $0.path == "empty" }) {
                return "browse: an unchanged folder was listed"
            }
            if !listed.folders.contains("empty") || !listed.folders.contains("added") {
                return "browse: a folder was missing from \(listed.folders)"
            }
            return nil
        } catch {
            return "browse: \(error.localizedDescription)"
        }
    }

    /// A normal snapshot keeps the directory record and does not bring the file list back into memory.
    private static func testSnapshotLeavesTheFileListEmpty() -> String? {
        let root = temp("memory-list")
        defer {
            Vault.retainFilesForTest = true
            try? FileManager.default.removeItem(at: root)
        }
        Vault.retainFilesForTest = false
        let source = root.appendingPathComponent("source")
        let vault = root.appendingPathComponent("vault")
        do {
            try FileManager.default.createDirectory(at: source.appendingPathComponent("nest"), withIntermediateDirectories: true)
            try Data("one".utf8).write(to: source.appendingPathComponent("nest/a.txt"))
            try Data("two".utf8).write(to: source.appendingPathComponent("b.txt"))
            guard let snap = try Vault.snapshot(source: source, vault: vault, label: "", reason: "manual", verify: false) else {
                return "memory: snapshot was empty"
            }
            if !snap.files.isEmpty {
                return "memory: the snapshot kept \(snap.files.count) files"
            }
            if snap.tree == nil || snap.tree?.isEmpty == true {
                return "memory: the snapshot has no directory record"
            }
            let loaded = try Vault.load(vault, snap.id)
            if loaded.files.count != 3 {
                return "memory: the version loaded \(loaded.files.count) files"
            }
            let dest = root.appendingPathComponent("out")
            try Vault.restore(vault: vault, snapshot: snap.id, dest: dest, allowInsideSource: false)
            if try Data(contentsOf: dest.appendingPathComponent("nest/a.txt")) != Data("one".utf8) {
                return "memory: the nested file did not restore"
            }
            return nil
        } catch {
            return "memory: \(error.localizedDescription)"
        }
    }

    private static func randomData(count: Int, seed: UInt64) -> Data {
        var mix = SplitMix64(state: seed)
        var data = Data(count: count)
        for index in 0..<count {
            data[index] = UInt8(truncatingIfNeeded: mix.next())
        }
        return data
    }

    private static func temp(_ name: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chronicle-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func mtime(_ url: URL) -> Int64? {
        var info = stat()
        if lstat(url.path, &info) != 0 { return nil }
        return Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }

    private static func setMtime(_ url: URL, _ nanos: Int64) -> Bool {
        let when = timespec(tv_sec: time_t(nanos / 1_000_000_000), tv_nsec: Int(nanos % 1_000_000_000))
        var times = [when, when]
        return url.path.withCString { utimensat(AT_FDCWD, $0, &times, 0) == 0 }
    }
}
