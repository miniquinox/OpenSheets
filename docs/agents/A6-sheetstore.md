# A6 — SheetStore: file sync, snapshots, workspace grants, persistence

**Wave 1 · parallel with A1–A5, A7 · blocked by A0.**

## Mission
Build the engine that makes "Claude Code edits the file, the app notices" actually work — reliably,
on the first try, forever. Read **PLAN.md §6 and §7** in full; §6.3's state machine is a literal spec.

This component is where subtle bugs become data loss. Bias every ambiguous decision toward
*never losing the user's edits* and *never corrupting the file*.

## Dependencies
A0 merged. You may `import SheetFormat` for its type signatures, but **do not wait on A1/A2** —
define your own narrow protocols (`WorkbookReading`, `WorkbookWriting`) and develop against fakes.
A8 injects the real implementations. This keeps you fully parallel.

## Files you own
```
Packages/OpenSheetsCore/Sources/SheetStore/**
Packages/OpenSheetsCore/Tests/SheetStoreTests/**
```

## Files you must NOT touch
`SheetFormat/**` (A1/A2), everything else.

## Build this

### 1. `FileWatcher` — get this right, it is the product
`DispatchSource.makeFileSystemObjectSource` on an open fd (`.write .rename .delete .extend .attrib`)
**plus** an `FSEventStreamCreate` on the parent directory. The fd source alone **misses atomic
replaces** — which is exactly how our own writer, and most Python/Node xlsx libraries, save. Watching
both is mandatory, not belt-and-braces.

- On `.rename`/`.delete`: re-resolve the path and **re-arm on the new fd**. Forgetting this is the
  classic bug where the watcher dies silently after the first save and the feature looks "flaky".
- Debounce 150 ms (writers emit bursts), then compare `(size, mtime, inode, first-4KB hash)` before
  doing any real work.
- Handle: file replaced by a directory, parent directory renamed, volume unmounted, iCloud/Dropbox
  placeholder not yet materialised (`NSURLUbiquitousItemDownloadingStatusKey`), and a writer that is
  still mid-write (truncated file — the hash check catches this; back off and retry).

### 2. `SelfWriteSuppressor`
Record an expected `(inode, size, mtime, hash)` fingerprint on every save; the watcher drops matching
events. Without this the app refresh-loops after every save. Fingerprints expire after 5 s so a
genuine external write immediately after ours is not swallowed.

### 3. `DocumentSyncState` — implement §6.3 literally
States: `SYNCED · STALE · RELOADING · DIRTY · CONFLICT · MISSING · LOCKED · READ_ONLY · UNREADABLE`.
Model it as an explicit `enum` + a transition function that is **unit-testable without any
filesystem**, and drive the real watcher into it. Every transition is a pure function of
(current state, event). Test the full transition table, including the illegal transitions.

### 4. `SheetDiff` computation
Between a pre-reload `Workbook` snapshot and a freshly parsed one:
- Sheets added / removed / renamed (match on sheet id first, then name, then content similarity).
- Per sheet: cells added / removed / changed, with before + after values.
- **Structural detection:** run a cheap LCS over per-row content hashes *first*, so inserting one
  row into a 10,000-row sheet reports *"inserted 1 row at 5"* and not 10,000 changed cells. This is
  the difference between a usable diff panel and an unusable one.
- Cap the reported cell list (e.g. 5,000) with an accurate "+N more" count; never build an unbounded array.
- Target: < 1 s for a 100k-cell workbook.

### 5. `SnapshotStore`
Gzipped raw file bytes in `~/Library/Application Support/OpenSheets/Snapshots/<sha256-of-path>/<ulid>.gz`.
Taken **before every external refresh and before every one of our own saves.** Last 20 per file,
oldest evicted, 500 MB global cap. `restore(id:)` writes atomically through the same path as a save
(so it too is fingerprinted and doesn't trigger a self-refresh). This is the safety net for
"Claude trashed my sheet" — it is a headline feature, not housekeeping.

### 6. `WorkspaceGrants` — the security boundary (PLAN.md §7.2)
`grant(url:)` from an `NSOpenPanel` result, persisting a security-scoped bookmark. `isAllowed(url:)`
enforcing **all** of:
- resolve symlinks and `..` **before** checking (`resolvingSymlinksInPath` then `standardized`);
- compare by **path components**, not string prefix (`/Users/q/work-secret` must not match `/Users/q/work`);
- a deny-list that overrides any grant: `~/.ssh`, `~/.aws`, `~/.config/gh`, `~/Library/Keychains`,
  `~/.claude.json`, `*.pem`, `*.key`, `.env*`;
- no API path by which a grant can be created except an explicit user action in the app.

### 7. `Database` — GRDB, WAL
The five tables in PLAN.md §5.5, with migrations. **Two processes** (app + `opensheets-mcp`) open
this concurrently — so: WAL mode, `busy_timeout`, and every write in a transaction. Test concurrent
access from two processes for real, not just two threads.

### 8. `AtomicWriter`
Temp file in the same directory → `fsync` file → `fsync` directory → `FileManager.replaceItemAt`.
Preserve POSIX permissions and extended attributes (Finder tags). Return the fingerprint for §2.
Clean up the temp file on every error path. (A2 also needs this; whoever lands first owns it and the
other imports it — coordinate through the integrator rather than duplicating.)

## Acceptance criteria
- [ ] **Watcher survives 100 consecutive atomic replaces** of the same path and fires exactly 100
      times. This single test is the one that matters most; write it first.
- [ ] Watcher fires for: in-place write, atomic replace, `mv` over the file, `rm` + recreate, edit
      from a different process, and edit via a symlink to the file.
- [ ] Self-write suppression: 50 saves in a row produce **zero** spurious refresh events.
- [ ] Full state-transition table tested with no filesystem (pure function tests), plus an
      integration test per state driven by real file operations.
- [ ] Diff: inserting one row into a 10,000-row sheet reports a structural insert, not 10k changes.
      100k-cell diff completes in < 1 s.
- [ ] Grant escape suite: `../`, symlink out of the workspace, `/Users/q/work-secret` vs
      `/Users/q/work`, hardlink, `~` expansion, `//` and `/./` normalisation, unicode-normalisation
      tricks, and every deny-listed path. **All denied.** ≥ 25 cases. Treat a single escape as a P0.
- [ ] Snapshot restore returns byte-identical original content and does not trigger a refresh loop.
- [ ] Two processes writing the DB concurrently for 30 s: no `SQLITE_BUSY` failures, no corruption.
- [ ] Kill -9 during a save leaves the original file intact.

## Report back
The public API A8 and A9 both consume, the state machine as you implemented it, and any watcher
behaviour you found on macOS 26 that differs from the docs.
