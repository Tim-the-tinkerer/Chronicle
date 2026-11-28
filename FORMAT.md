# CHRONICLE/1

A Chronicle vault is a folder. The watched tree is not inside it.

```
vault/
  FORMAT                 the text CHRONICLE/1 and a newline
  vault.json             name, source, chunk parameters, skip list
  lock                   cooperative lock, not part of the history
  pending                present only while a snapshot is unfinished
  chunks/ab/<sha256>     one file per unique chunk
  trees/ab/<sha256>      one file per unique directory record
  snapshots/<id>.json    the version
  snapshots/<id>.head.json
  thinning.json          optional log of passes that removed versions
```

`<id>` is `yyyyMMdd-HHmmss` in UTC, a hyphen, and 8 lowercase hex digits. Example: `20261120-153012-a1b2c3d4`.

## thinning.json

Optional. Absent until thinning removes a version. Not required to restore.

`since` is when logging began. `removed` and `freed` are the totals from that pass onward, including passes that are no longer listed. `passes` keeps the newest 40, newest first. Each pass has `at`, the versions it removed (`id` and `created`), `freed`, and `complete`. A pass with `complete` false adds nothing to `freed`. A file that will not parse is left unchanged. Moving the history copies this file.

## vault.json

```json
{
  "format": "CHRONICLE/1",
  "id": "uuid",
  "name": "Writing",
  "source": "/Users/tim/Documents/Writing",
  "created": "2026-11-20T15:30:12.000Z",
  "chunk": { "min": 8192, "avgBits": 15, "max": 131072, "window": 32 },
  "skipNames": [".DS_Store", ".build", ".git", ".localized", ".swiftpm", "DerivedData", "node_modules"]
}
```

Chunk parameters are fixed for the life of the vault. A later snapshot uses the stored parameters, so identical bytes keep the same cuts.

A usual name on `skipNames` is omitted wherever it appears. A name Add Folder adds is only that top-level folder. When the omitted name is a directory, its contents are omitted too. A skipped file is omitted alone and does not hide the rest of its folder. Symlinks are stored as the link text and are not followed. A later snapshot uses the stored list.

## Snapshot

`<id>.json` is the version. `<id>.head.json` repeats everything except `files`, `tree`, and `skipped`, so a list of versions does not have to read every chunk list.

A new version stores `tree` and omits `files`. `tree` is the SHA-256 of the root directory record. A version written before that still stores `files` and omits `tree`. A reader uses `files` when that array is present and non-empty, and otherwise expands `tree`. Cleanup and Verify History follow that rule, so an empty `files` array keeps the chunks named by `tree`.

```json
{
  "format": "CHRONICLE/1",
  "id": "20261120-153012-a1b2c3d4",
  "parent": null,
  "created": "2026-11-20T15:30:12.123Z",
  "label": "",
  "reason": "manual",
  "source": "/Users/tim/Documents/Writing",
  "tree": "<64 lowercase hex>",
  "files": [
    {
      "path": "notes/draft.txt",
      "kind": "file",
      "mode": 420,
      "mtimeNS": 1730000000123456789,
      "size": 12,
      "chunks": ["<64 lowercase hex>"],
      "lengths": [12],
      "target": null
    }
  ],
  "skipped": [],
  "stats": {}
}
```

The example shows every field. A published version has `tree` and no `files` array. An older version has `files` and no `tree`.

A directory record is a JSON array of names, sorted by `name`, hashed with SHA-256, and stored at `trees/ab/<hash>` with the chunk header below. LZFSE is used on the same rule as a chunk. The decoded JSON is at most 32 MiB. Chronicle refuses to store a larger record, and does not publish that version. A regular directory-record file larger than the 16-byte header plus 32 MiB is treated as damaged and rewritten the next time that record is stored. It is not renamed.

```json
[
  {"name": "draft.txt", "kind": "file", "mode": 420, "mtimeNS": 1730000000123456789, "size": 12, "chunks": ["<64 lowercase hex>"], "lengths": [12]},
  {"name": "notes", "kind": "dir", "mode": 493, "mtimeNS": 1730000000123456789, "tree": "<64 lowercase hex>"}
]
```

`name` is one path component. A directory's `tree` is the child record. A file carries `size`, `chunks`, and `lengths`. A symlink carries `size` and `target` and is not followed. The same bytes are the same hash, so an unchanged directory is one file shared by every version that still has it.

`kind` is `file`, `dir`, or `link`. `mode` is the permission bits (`st_mode & 0777`). `mtimeNS` is the modification time in nanoseconds since the Unix epoch. `0` means the file was still being written while it was read, and a restore leaves the destination's modification time alone.

`chunks[i]` is the SHA-256 of uncompressed chunk `i`. `lengths[i]` is that chunk's uncompressed size. The lengths sum to `size`. Directories and symlinks have empty chunk lists. A symlink's `target` is the link text, not a resolved path.

Paths are relative, use `/`, and contain no empty, `.`, or `..` component.

`reason` is `first`, `manual`, `watch`, `catchup`, or `cli`. `catchup` is the check Chronicle runs when it opens. `parent` is the previous version's id, or null. Deleting a middle version, or thinning one, leaves a dangling parent. The newer version still restores. Its comparison uses the newest version that still exists before it, and the new-byte count shown for that version is measured against that same predecessor. The count stored in the version file is left as it was. The comparison waits only when no earlier version still loads. The version list does not open every version to show that count. While `<parent>.json` is still in the snapshots directory, the row uses the counts in the head. When that file is missing, the row is measured against the predecessor above, once, and that measurement is kept. If the snapshots directory cannot be listed, every row uses the counts in its head.

`stats` counts files, directories, links, logical bytes, new uncompressed chunk bytes, reused uncompressed chunk bytes, and added, changed, removed, and unchanged paths. Files, links, and directories all count in the added, changed, and removed numbers. A directory counts as changed when its kind or permission bits differ. Its modification time does not, so a skipped file such as `.DS_Store` can move the directory time without a new automatic version. `skippedCount` counts skipped paths. The stored `skipped` array keeps at most 200 of them.

`carriedFiles` counts files and links whose current bytes could not be read, so the previous copy was kept. `unreadFiles` counts paths that could not be read and had no previous copy. Neither count includes a path skipped by name, such as `.git` or `node_modules`. Older manifests omit these two fields; a reader treats them as zero. An automatic version is kept when a path was added, removed, or changed, or when those carried and unreadable paths are not the same set as the parent. The same set on a later automatic run does not save a version. The counts stay on a version that is kept. A manual, first, or command-line snapshot is always kept.

`<id>.json` is the commit. Chunk bytes and directory records are stored before it. Each new chunk and directory record is fsynced, and so is the directory entry that names it. Chronicle writes `<id>.json.partial`, fsyncs that file, then calls `F_FULLFSYNC` on it, and renames it to `<id>.json`. That one `F_FULLFSYNC` flushes the drive cache. The rename is the publication. The snapshots directory is fsynced after the rename. A failure before that rename deletes the partial file, the new chunks, and the new directory records, and the version does not appear. A chunk that cannot be stored fails the same way. That file is not recorded as unreadable. `<id>.head.json` is a rebuildable index of the version list. A missing or unreadable head is rebuilt from the version file. A head whose version file is gone is not listed. Opening the history removes that head file. A check of the history reads each `<id>.json` directly, so a damaged manifest is still found when its index is missing. The source path in `vault.json` is written after the commit. If either later write fails, the version stays. If the process stops before the rename, `pending` is still there. The next locked snapshot deletes leftover partial manifests and chunks that no readable version names. If that cleanup cannot finish, `pending` stays so a later open retries it. A snapshot does not clear the marker in that case. If the version list cannot be read, or a version file cannot, or a directory record cannot, it does not delete chunks or directory records. A damaged newest version file does not block the next snapshot; that snapshot's parent is the newest version file that still loads.

After a version is published, and when Chronicle opens a history, versions are thinned by the UTC time in the id. The last 24 hours are kept in full. From there through 30 days, the oldest version in each hour is kept. Older than 30 days, the oldest version of each day is kept. The newest version is always kept. An id that is not a time is kept. A version with a label is kept, and so is one whose reason is `manual`. The label and the reason are read from `<id>.head.json`. Neither pin takes the hour or day slot from an unlabeled version. A head that cannot be read keeps that version. Thinning does not open the version body to decide, so a history whose heads cannot be read is left as it is. Thinning removes the other version files and then the chunks and directory records no remaining version names. An unreadable version stops that second step.

A snapshot compares each file with the parent. Same relative path, same size, and same `mtimeNS` reuses the parent's chunk list and does not read the file. Anything else is read and cut again. Bytes whose chunk hash is already in the vault count as reused. The stored chunk file is not read back. A missing chunk file is written. Verify History reads a stored chunk. When those bytes were read and the hash does not match, or the chunk would not decompress, it renames that file to `<hash>.damaged` and reports it. A regular chunk file larger than the 16-byte header plus 8 MiB is damaged the same way, and it is set aside without being read. An older `<hash>.damaged` file is replaced so it does not block that rename. A read that fails is reported as a chunk that could not be read, and the file stays. The next re-read sees a renamed chunk as missing and writes a good copy. Cleanup deletes `<hash>.damaged` once that good copy is stored. Until then the damaged file stays, including when cleanup cannot read every version.

## Chunk file

The file name is the lowercase hex SHA-256 of the uncompressed bytes. The first two hex digits are the directory.

```
0  4   magic CK01
4  1   method: 0 raw, 1 LZFSE
5  3   zero
8  8   uncompressed size, little-endian uint64
16 …   payload
```

LZFSE is used when the payload is at least 32 bytes smaller than the raw chunk and the chunk is at least 64 bytes. A reader checks the magic, the size (at most 8 MiB), and that the SHA-256 of the decoded bytes matches the file name. A stored chunk file is at most that 16-byte header plus 8 MiB. A larger regular file is damaged and is not read.

## Chunker

The cut is a 64-bit buzhash so an insert or a small overwrite realigns on the far side of the edit.

The 256-word table comes from SplitMix64. The seed is `0xC47041C1C1E50001`. Each step is the usual SplitMix64: add `0x9E3779B97F4A7C15`, then

```
z = (z xor (z >> 30)) * 0xBF58476D1CE4E5B9
z = (z xor (z >> 27)) * 0x94D049BB133111EB
z = z xor (z >> 31)
```

with all arithmetic mod 2^64. A zero word is replaced with `0x9E3779B97F4A7C15`.

State starts at 0 at the first byte of each chunk. For each byte `b`:

1. Rotate the state left by 1.
2. XOR `table[b]`.
3. Once 32 bytes have been fed in this chunk, XOR `rotateLeft(table[outgoing], 32)`, where `outgoing` is the byte 32 positions back.

The chunk ends on the byte that makes the length equal `max`, or makes the length at least `min` and `state & mask == 0`. That byte is included. The next chunk starts on the next byte with state 0.

`mask` is `(1 << avgBits) - 1`. The standard parameters are min 8192, avgBits 15, max 131072, window 32. A file shorter than the minimum, including an empty file, is one chunk or none.

## Restore

Restore creates the destination, writes files from their chunks, recreates symlinks, then applies directory modes and modification times from the deepest directory upward. It refuses a relative path that leaves the destination, and it refuses to follow a symlink while creating destination directories. It does not delete extra files already in the destination.

The app refuses a destination inside the watched folder and inside the vault. The command line flag `--into-source` is the opt-in for writing inside the watched folder.
