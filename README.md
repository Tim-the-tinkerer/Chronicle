# Chronicle

A personal time machine for one folder at a time. Chronicle watches the folder and keeps every version. Each version stores only what changed.

The cost of a full copy, times the number of versions, is what history usually costs. Chronicle keeps the new bytes.

**Version:** 1.0.20 — see [CHANGELOG.md](CHANGELOG.md). The vault format is [FORMAT.md](FORMAT.md), `CHRONICLE/1`.

## What you see

Add a folder. The first snapshot reads it. After that, the header is the product:

- **Stored** is the history on disk.
- **Full copies** is what the same versions would weigh if each one were a complete copy.
- **Saved** is the difference, as a percent.

A version row says how many new bytes it stored, and how large a full copy of the folder would have been. Pick a version to see which files were added, changed, or removed, and how much of a changed file is actually new. A file whose only change is its permissions is shown as changed.

Snapshot (⌘S) writes a version now. A second request while one is running waits its turn. Re-read Every File (⌥⌘S) reads every byte, including files whose size and modification time did not change. Restore writes a new folder somewhere else, or one file. Approving a replace writes that file beside the one already there and puts it in place only after every chunk has been read. A damaged chunk leaves the original file where it is. Delete Version drops that manifest and the chunks no other version uses.

The schedule is every 15 minutes by default. It can be hourly, daily, or manual. One folder that is missing, or whose drive is unplugged, does not keep the others from saving. An automatic check that finds nothing waits out that folder's interval. An automatic version is written when a file, a symlink, or a directory was added, removed, or changed. A directory whose only change is its modification time does not count. Opening the folder in Finder moves that time when it writes a skipped name such as `.DS_Store`. The same unreadable folder, or the same unreadable file, does not start another automatic version. The first time a path cannot be read, Chronicle saves one. A version saved for another reason still says how many files were carried forward. A manual snapshot still saves.

Every version from the last 24 hours is kept. After that Chronicle keeps the oldest version in each hour for 30 days, then the oldest version of each day. The newest version stays. Opening Chronicle applies that to the history already on disk. When Chronicle removes older versions, it names them and says how much space that freed. If the kept versions still use those bytes, it says so. Each folder keeps a thinning history under its version list. That history records when a pass removed versions, which versions, and how much space it freed, and it shows a total since logging began. Earlier runs are not included. The version list updates after a snapshot, a delete, a cleanup, and that thinning. The newest day stays open. Each earlier day is collapsed until you open it to look at those versions or restore one. A refresh that started earlier does not replace the list. Switching folders clears that list immediately, so a version from one folder cannot be deleted or restored as if it belonged to another. A label typed for one folder is not applied when the menu snapshots a different folder.

Opening Chronicle checks each automatically watched folder against its latest version and saves a version when something changed while the app was closed, including an empty folder added or removed. A folder it still cannot read is not, by itself, a change. That check uses each file's size and modification time. Re-read Every File reads every byte. A manual folder is left until you snapshot it. Opening a history, and the check the schedule does every 20 seconds, read the drive without blocking the window.

Closing the window leaves Chronicle in the menu bar and takes it out of the Dock. The schedule keeps running. The menu lists each folder, can snapshot one, and has Show Chronicle. Quit is in that menu. Close does not quit.

History lives on this Mac by default, in `~/Library/Application Support/Chronicle/Vaults/`. When you add a folder, you can keep the snapshots there, or choose a folder or another drive. Store Snapshots copies an existing history to the new place, checks every version there, and compares those version ids with the original. It saves the new location and removes the old copy only when the ids match. An interrupted copy, a version list that cannot be read, or a short copy leaves the original where it is. The next folder you add can use that place again. The watched folder is only read. Show History opens the snapshot folder. If the drive is unplugged, the folder stays in the list and Chronicle says the snapshots are unavailable.

## The engine

Files are cut with a content-defined chunker (a 64-bit buzhash, 32-byte window, 8 KB minimum, 128 KB maximum). Each chunk is named by the SHA-256 of its bytes. A version is a list of those names. A chunk that already exists is not written again.

An edit in the middle of a large file changes the chunks around the edit. The rest of the file is the same names as last time. Two files with the same bytes share one copy. A stretch of identical bytes inside one file does too.

Chunks are stored with a small header. The payload is LZFSE when that is smaller than the raw bytes, otherwise raw. The hash is always of the uncompressed bytes.

A file whose size and modification time match the previous version is not read again. Its previous chunk list is reused. That is the fast path. Re-read Every File, and `snapshot --verify`, read every file. A rewrite that puts the old modification time back is invisible to the fast path and visible to a re-read. A chunk file that is already stored is reused without being read back. Verify History is the check for a damaged chunk. It renames that file to `.damaged` only when the bytes were read and the hash did not match, or the chunk would not decompress. A chunk file larger than Chronicle allows is set aside the same way, without reading it. An older `.damaged` file does not block that. A read that fails is reported and the file stays. Cleanup removes the `.damaged` file once a good copy of that chunk is stored again. A missing chunk file is written when those bytes are read.

A version names one directory record. That record is the list of names in the directory, and a subdirectory is another record, named by the SHA-256 of its list. An unchanged directory keeps its name, so the next version does not store it again. Each record uses the same LZFSE header as a chunk. A record larger than Chronicle allows is not stored, and that version is not published. A version saved by an older Chronicle still has its full file list, and still opens. A version whose file list is empty keeps the chunks named by its directory record.

The version file is the commit. Its chunks and directory records are stored first. Each new chunk and directory record is fsynced, which submits it to the drive. Chronicle writes `snapshots/<id>.json.partial`, fsyncs that file, then calls F_FULLFSYNC on it, and renames it to `snapshots/<id>.json`. That one F_FULLFSYNC flushes the drive cache. That rename publishes the version. The directory that holds the version is fsynced after the rename. The head file is an index. A missing or unreadable head is rebuilt from the version file. A head with no version file is left out of the list, and opening the history removes it. A failure before the rename removes the new chunks and new directory records, and the failed version never appears. A chunk that cannot be stored fails the same way. The file is not saved as unreadable. A failure while writing the head leaves the version in place. If cleanup could not finish when the snapshot opened, the crash marker stays so the next open can try again. Cleaning unused chunks reads every version file first. If that list cannot be read, or a version file cannot, or a directory record cannot, the chunks stay on disk. A version file that cannot be read does not stop the next snapshot. The new version follows the newest one that still can.

The last day of versions is kept. Older history is thinned to one an hour for 30 days, then one a day. A version you labeled is kept, and so is a manual snapshot. Thinning reads the label and the reason from the head file. A version whose head cannot be read is kept. The version body is not opened to decide. The file list compares a version with its parent, or with the newest version still there when that parent was removed. A version row uses the counts saved with that version while the parent file is still there. When the parent file is missing, the row is measured once and that measurement is kept.

If Chronicle cannot read a file, the version says so. An older copy is carried forward when one exists: “Saved, with 2 files carried forward.” A file kept because its folder could not be listed is marked the same way. A file with no older copy is unreadable. Names such as `.git` and `node_modules` stay in the skip list and are not part of that warning. The same unreadable paths on the next automatic run do not save another version.

Verify History reads every version file, including one whose index is missing, then checks the SHA-256 of every chunk and directory record that version names. A version file that cannot be read is listed. If the version list itself cannot be read, the check fails instead of reporting an empty history. One damaged or missing chunk, or one damaged or missing directory record, is listed with every version that uses it.

## What a version keeps

For each file: relative path, kind, permission bits, modification time, size, and the chunk list. Symlinks store the target and are not followed. Empty directories are kept.

Skipped anywhere in the tree: `.DS_Store`, `.localized`, `.git`, `.build`, `.swiftpm`, `DerivedData`, `node_modules`. The list is written into the vault. A skipped file is left out by itself. A skipped directory is left out with everything inside it. A symlink is stored and is not followed, and it does not hide the next folder.

Resource forks, Finder tags, ACLs, and file owners are not stored. Hard links become separate files that share chunks when the bytes match. A socket, device, or unreadable file is listed as skipped. An unreadable file that was in the previous version keeps that previous copy.

## Command line

```bash
Chronicle snapshot --source ~/Documents/Writing --vault ~/Backups/Writing.chronicle
Chronicle list --vault ~/Backups/Writing.chronicle
Chronicle stats --vault ~/Backups/Writing.chronicle
Chronicle diff --vault ~/Backups/Writing.chronicle
Chronicle restore --vault ~/Backups/Writing.chronicle --snapshot ID --dest ~/Desktop/Writing-restored
Chronicle restore-file --vault ~/Backups/Writing.chronicle --snapshot ID --path notes/draft.txt --dest ~/Desktop/draft.txt
Chronicle delete --vault ~/Backups/Writing.chronicle --snapshot ID
Chronicle gc --vault ~/Backups/Writing.chronicle
```

`--into-source` is the explicit opt-in for a restore that writes inside the watched folder. The app does not offer that.

## Requirements

macOS 13 or later, and the Xcode toolchain. SwiftUI from the Command Line Tools is missing the macro plugin this app needs.

## Build

```bash
cd ~/Apps-Usefull/Chronicle
chmod +x build-app.sh
./build-app.sh
```

Build without launching:

```bash
./build-app.sh --no-launch
```

The engine checks:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run -c release Chronicle --self-test
```
