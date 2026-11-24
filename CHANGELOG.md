# Changelog

## 1.0.17

- Restoring over a file writes the copy beside it and replaces the original only after every chunk has been read. A damaged chunk leaves the file that was already there.

## 1.0.16

- A missing folder or an unplugged drive no longer keeps the schedule from saving the other folders. An automatic check that saves nothing waits out that folder's own interval before it runs again.
- A check that finds nothing while another folder is selected no longer leaves "Reading the folder…" on screen.
- Restore and Delete keep the version you confirmed if the list moves while the dialog is open.
- A folder watched inside another watched folder both notice a change inside the inner one.
- A snapshot that cannot store a chunk stops. The previous version stays, and the file is not saved as unreadable.
- A directory record larger than Chronicle allows is not published. The new chunks from that attempt are removed.
- A file kept because its folder could not be listed is shown as carried forward.
- A path repeated in a damaged version is listed once when that path is removed.

## 1.0.15

- Switching folders clears the version list immediately. Delete and Restore cannot apply one folder's version to another. A file list that was still loading for the previous folder is ignored.
- Remove, Delete, Restore, and Store Snapshots do not start if Chronicle began another job while the confirmation was open.
- A snapshot leaves the crash marker in place when opening the history could not finish cleanup. The next open retries that cleanup.
- Verify History can set a chunk aside when an older `.damaged` file is already there.
- A file whose only change is its permissions is shown as changed.

## 1.0.14

- The version list is not replaced by a refresh that started earlier. It updates after a snapshot, a delete, a cleanup, and the thinning that runs when Chronicle opens.
- A label typed for one folder is not applied when the menu snapshots a different folder.
- A version whose file list is empty keeps the chunks named by its directory record. Cleanup and Verify History use that record.
- A head file with no version file is left out of the list. Opening the history removes that head.
- A chunk file larger than Chronicle allows is treated as damaged and set aside without reading it.

## 1.0.13

- The version list uses the counts already saved with each version. It remeasures a row only when that version's parent file is missing, and it remembers that measurement.
- Verify History sets a chunk aside only when the bytes were read and the hash did not match, or the chunk would not decompress. A read that fails is reported and the file stays. Cleanup removes a `.damaged` file once a good copy of that chunk is stored again.
- Thinning reads a version's label and reason from its head file. A version whose head cannot be read is kept. The version body is not opened to decide.

## 1.0.12

- A labeled version is kept, and so is a manual one. Thinning no longer deletes them because an older version from the same hour or day is the one that hour or day keeps.
- When a version's parent was removed, the file list compares it with the newest version that is still there. The new-byte count on that row uses the same version. The count stored in the version file is left as it was.
- Each new chunk and directory record is fsynced. One F_FULLFSYNC, on the version file, runs just before that file is renamed into place.
- Verify History renames a damaged chunk to `.damaged`. The next Re-read Every File writes a good copy.
- A symlink to a folder no longer hides the next folder.

## 1.0.11

- The chunker finds cut points by index and copies each chunk once. The boundaries are unchanged.
- A snapshot reuses a chunk file that is already stored without reading it back. Verify History still checks those bytes. A missing chunk file is written when the bytes are read.
- Opening a history, and the schedule's check every 20 seconds, read the drive off the main thread.
- A snapshot requested while one is running waits behind the requests already waiting.
- Deleting a version recognizes an unreadable version list by the error itself. `catchup` is a snapshot reason, the check Chronicle runs when it opens.

## 1.0.10

- New and replaced chunks and directory records are forced to the drive with F_FULLFSYNC before the version file is published. The version file is forced the same way. A saved version no longer names chunks that were still only in the drive cache.
- An automatic snapshot no longer saves a version when the only difference is the same unreadable folder or the same unreadable file. The first time a path cannot be read is still saved. A version saved for a real change still says how many files were carried forward.

## 1.0.9

- A version stores a directory record instead of a line for every file. An unchanged directory is kept once and shared, and each record is compressed with the same LZFSE header as a chunk. Older versions that still list every file still open.
- Versions older than 24 hours are thinned to one per hour for 30 days, then one per day. The newest version stays.

## 1.0.8

- A skipped file such as `.DS_Store` no longer hides the rest of its folder. A skipped directory such as `.git` or `node_modules` is still left out with everything inside it.

## 1.0.7

- Cleanup no longer deletes chunks when the version list or a version file cannot be read. A damaged newest version does not block the next snapshot.
- Storing bytes whose chunk is already on disk replaces that file when it is damaged. A broken version index is rebuilt from the version file.
- A repeated path in a version no longer crashes a snapshot or a comparison. The folder watch treats `/var` and `/private/var` as the same folder. Command-line diff includes files that were carried forward or could not be read.
- If a snapshot is already running when Chronicle opens, the launch check of the other automatic folders still runs after it.

## 1.0.6

- Verify History fails when the version list cannot be read, instead of treating that failure as an empty history.
- A move compares the version ids on the copy with the original and keeps the original when they differ.

## 1.0.5

- Moving a history copies it to the destination, checks every version there, saves the new location, and only then removes the old copy. An interrupted copy leaves the original in place.
- Verify History reads every version file. A damaged manifest with no index is reported instead of skipped.

## 1.0.4

- Closing the window leaves Chronicle in the menu bar. Watched folders keep their schedule. Show Chronicle opens the window. Quit is in that menu.

## 1.0.3

- A folder’s history can live in a folder you choose, or on another drive. On this Mac is still the default. Store Snapshots moves an existing history. The watched folder stays where it is.
- If that drive is unplugged, the folder stays in the list and Chronicle says the snapshots are unavailable.

## 1.0.2

- Opening Chronicle saves a version of each automatically watched folder when it changed while the app was closed. The check uses size and modification time.
- The version file is published by renaming a partial manifest into place. A failed publish leaves the previous version and does not show the failed one.
- A version says when files were carried forward or could not be read. Skip-list names are not part of that warning.
- Verify History checks every chunk and lists the versions a missing or damaged chunk affects.

## 1.0.1

- Opening the app compares each watched folder with the latest version, so an edit made while Chronicle was closed is picked up by the schedule.
- The version file is the commit. A failure after it is published keeps that version and its chunks.
- An automatic version is kept when a directory is added, removed, or its permissions change. A directory modification time alone is not a change.

## 1.0.0

- Watches a folder and keeps a version of it.
- Each version stores the chunks that changed. Unchanged files are a line in the manifest.
- A small edit inside a large file keeps the surrounding chunks.
- Identical copies, including repeated stretches of the same bytes, are stored once.
- New chunks are packed with LZFSE when that is smaller.
- Restore writes a new folder, or one file. The watched folder is left alone.
- Schedule is manual, every 15 minutes, hourly, or daily. An automatic version is kept when something changed.
- Command line: `snapshot`, `list`, `diff`, `stats`, `restore`, `restore-file`, `delete`, `gc`.
