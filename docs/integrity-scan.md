# Integrity scan: `easy_sync scrub` (built and verified on real hardware)

This was the build spec and is now checked against the implementation:
`Jbod::Scrubber`, `Jbod::PageCache`, the `file_checksums` table,
`Mirror#refetch`, and the `sync`/`status`/dashboard/`restore` integrations
described below all exist and are covered by specs. The real-hardware
checklist at the bottom passed on 2026-09-21; results are recorded there. If
anything here disagrees with the code, the code wins; fix this doc.

## Problem

rsync checks data while it copies it. Nothing checks it afterwards. If a bit
flips on a backup drive a year later, the file keeps the same size and mtime,
so rsync's quick check skips it on every future sync. APFS checksums metadata,
not file contents. The bad copy stays there, unnoticed.

This matters here because **the offsite backup (Backblaze Personal) is taken
from the drives, not from the NAS.** Backblaze sees a rotted file as a changed
file and uploads it. The NAS still has the good version, but nothing tells you
to go and get it.

What is already covered, and so is out of scope:

- **The NAS.** Synology's monthly Btrfs scrub detects rot and repairs it from
  redundancy.
- **Legitimate changes on the NAS**, including ransomware or a bad app write
  that sync then copies over the good backup. That is a different feature:
  `docs/tripwire.md`. `scrub` treats any change in size or mtime as
  legitimate on purpose.

## How it works (summary)

1. `easy_sync scrub` picks one mounted drive, the one that has gone longest
   without a full check.
2. It walks that drive's assigned folders on local disk. It adds a row for
   each new file, drops rows for files that are gone, and resets the row of
   any file whose size or mtime changed (a legitimate re-sync).
3. It hashes files with SHA-256 in frontier order: files that were flagged
   and then refetched come first, then files never hashed, then the oldest
   hashed. It compares each hash to the stored one.
4. A mismatch marks the row `corrupt`. A read error marks it `unreadable`.
   `scrub` never changes anything on the drive.
5. On the next `sync` of that folder, after the normal copy pass succeeds,
   sync re-copies the flagged files from the NAS with `rsync -I` (ignore
   times). rsync writes each one to a temp file and renames it over the bad
   copy. Nothing is deleted.
6. The next `scrub` of that drive re-hashes the refetched files. If the hash
   matches the original baseline, the row goes back to `ok` ("repaired"). If
   it still does not match, the row becomes `unresolved`: it is reported and
   never refetched again automatically.

`sync` never hashes anything. The only change to sync is step 5, and it runs
only for folders that have flagged files.

## Decisions (settled, don't re-open)

- **The command is `scrub`, not `verify`.** `verify-drive` already exists and
  does something unrelated: it records a clean SpinRite pass and resets the
  reallocated-sector baseline (`cli.rb` `verify_drive`). Two commands called
  `verify` would be confusing.
- **One drive at a time.** Each drive is scrubbed completely, in sequence.
  There is no interleaving across drives and no budget split between them.
  Drives are connected now and then rather than kept mounted, so the normal
  use is: connect the drives, run `scrub --all`, leave it. At about 200 MB/s,
  the fullest drive today (backup-01-8tb, 5.8 TB used) takes about 8 hours,
  and the whole fleet (about 35 TB) takes about 2 days.
- **`scrub` discovers files by walking, not `sync`.** A walk of one local
  APFS drive takes seconds to minutes, next to hours of hashing. The same walk
  handles the first run and every later one. It also cleans up after purge,
  clean, reassign and re-sync without those code paths knowing about checksums.
  (An earlier draft had `sync` add rows from its `--itemize-changes` output.
  That was dropped because a failed or interrupted copy pass would leave
  fully-copied files without rows. They then match on the next run, rsync
  never lists them again, and they are never picked up.)
- **Repair by overwriting, never by deleting.** `rsync -I --files-from`
  replaces the flagged file atomically. The invariant "only `Purger`
  deletes" stays true. There is never a moment when the file is missing.
- **SHA-256, computed in Ruby.** Do not use rsync's `%C` checksums. They
  only cover files rsync transferred, they need `--checksum-choice=md5`, and
  MD5 and xxh128 are not sound choices here. SHA-256 runs at about 2.5 GB/s
  on Apple Silicon, so the disk is always the bottleneck.
- **Read past the page cache.** Set `F_NOCACHE` on each file descriptor
  (`io.fcntl(48, 1)` on macOS, best effort: rescue `SystemCallError` and
  carry on), **and** evict the file's pages first (`Jbod::PageCache.evict`:
  mmap + `msync(MS_SYNC | MS_INVALIDATE)` via Fiddle, best effort).
  Without both, a file sync just wrote is hashed from RAM and the platter is
  never checked. The Mac has 24 GB of RAM, so this is the normal case, not a
  corner case. `F_NOCACHE` alone was measured **not** to be enough: it keeps
  a read from *adding* pages to the cache, but pages already there are still
  served from RAM (a just-synced file scrubbed at 2,084 MB/s from a USB
  drive; after eviction, 145 MB/s).
- **Trust on first use.** The first hash of a file becomes its baseline. A
  file that was already bad when it was copied gets a bad baseline, and
  `scrub` cannot know. Btrfs scrub on the NAS is the check for that side.
- **Staleness threshold is 30 days** (`scrub_stale_days: 30`). It matches
  Backblaze's rule that a drive not connected for 30 days drops out of the
  current backup, so there is one number to remember.
- **Not in v1:** scrubbing drives in parallel, duplicate detection (a GROUP
  BY on `digest` later), scheduling (launchd), SnapRAID. SnapRAID has no
  checksum-only mode, and its parity would need a 7.28 TB drive the fleet
  cannot spare.

## Schema

Add this in `Manifest#migrate!` using `CREATE TABLE IF NOT EXISTS`. Don't
gate it on `user_version` (see CLAUDE.md: the real manifest is stamped 5).

```sql
CREATE TABLE IF NOT EXISTS file_checksums (
  drive_serial  TEXT    NOT NULL REFERENCES drives(serial_number),
  folder_path   TEXT    NOT NULL,              -- folders.folder_path, e.g. "movies/Heat (1995)"
  relative_path TEXT    NOT NULL,              -- path inside the folder
  size_bytes    INTEGER NOT NULL,
  mtime         INTEGER NOT NULL,              -- File.lstat.mtime.to_i
  digest        TEXT,                          -- hex SHA-256 baseline; NULL = never hashed
  verified_at   TEXT,                          -- last time the hash matched (or was first set)
  status        TEXT    NOT NULL DEFAULT 'ok', -- ok | corrupt | unreadable | unresolved
  failed_at     TEXT,                          -- when status last left 'ok'
  refetched_at  TEXT,                          -- set by sync after a successful refetch
  PRIMARY KEY (drive_serial, folder_path, relative_path)
);
CREATE INDEX IF NOT EXISTS idx_file_checksums_frontier
  ON file_checksums(drive_serial, status, verified_at);
```

The key includes `drive_serial` because `reassign` and `replace-drive` move a
folder between drives. Rows always describe one physical copy.

The file on disk is at `File.join(mount_point, folder_path, relative_path)`.
That is the same join `Runner#sync_folder` uses to build its destination.

## Component 1: `Jbod::Scrubber` (`lib/easy_sync/jbod/scrubber.rb`)

`Scrubber.new(manifest, excludes:, clock:, out:, deadline: nil, dry_run: false)`,
then `#run(mounted_drive) -> Result`. Each call handles one drive.

### 1a. Reconcile (walk)

For each folder in `manifest.folders_on(serial)`:

- `root = File.join(mount_point, folder_path)`. If it doesn't exist yet
  (assigned but never synced), skip it.
- Use `Find.find(root)` to find regular files only (check with `File.lstat`;
  skip symlinks). Prune any entry whose basename matches an `exclude_folders`
  pattern (`File.fnmatch(pat, name, File::FNM_DOTMATCH)`).
- Compare with the folder's existing rows:
  - **File with no row:** insert it with `digest` NULL.
  - **Row with no file:** delete the row.
  - **Size or mtime differs:** it was legitimately re-synced. Set the new
    size and mtime, set `digest`, `verified_at`, `failed_at` and
    `refetched_at` to NULL, and set `status` to `'ok'`.

Then delete this drive's rows whose `folder_path` is no longer assigned to
this drive (the folder was reassigned, removed or purged).

Write in one transaction per folder.

### 1b. Work queue (frontier)

```sql
SELECT * FROM file_checksums
 WHERE drive_serial = ?
   AND (status = 'ok'
        OR (status IN ('corrupt','unreadable') AND refetched_at IS NOT NULL))
 ORDER BY
   CASE WHEN status <> 'ok'   THEN 0   -- 1: confirm refetched repairs
        WHEN digest IS NULL   THEN 1   -- 2: never hashed
        ELSE 2 END,                    -- 3: re-check, oldest first
   verified_at, folder_path, relative_path
```

Two kinds of row are skipped: `corrupt` or `unreadable` rows still waiting for
sync to refetch them (re-hashing them proves nothing new), and `unresolved`
rows.

### 1c. Hash each file and record the result

Stop before starting the next file if `deadline` has passed. A file already
being hashed runs to completion.

Before each file, check that the drive's marker
(`<mount>/.easy_sync/drive.json`) still exists. If it doesn't, the drive was
unmounted: stop this drive, report it, and don't touch the row.

Hash with `Digest::SHA256`, reading in 8 MB chunks, with `F_NOCACHE` set and
the file's cached pages evicted first (see "Read past the page cache").
Then update the row:

| row before | read result | row after | reported as |
|---|---|---|---|
| `ok`, digest NULL | read OK | digest set, `verified_at`=now | new baseline |
| `ok`, digest set | matches | `verified_at`=now | ok |
| `ok`, digest set | differs | `status`=`corrupt`, `failed_at`=now; digest **kept** | **CORRUPT** |
| any | `Errno::EIO` | `status`=`unreadable`, `failed_at`=now | **UNREADABLE** |
| `corrupt`/`unreadable` + refetched, digest set | matches | `status`=`ok`, `verified_at`=now, clear `failed_at`/`refetched_at` | repaired |
| `unreadable` + refetched, digest NULL | read OK | digest set, `status`=`ok`, clear flags | repaired |
| `corrupt`/`unreadable` + refetched | differs, or EIO again | `status`=`unresolved` | **UNRESOLVED** |
| any | `Errno::ENOENT` | delete the row | (not reported) |

Keep the digest on `corrupt`. It is the known-good value that confirms the
repair later.

Commit at least every 30 seconds and on exit, including Ctrl-C (`Interrupt`).
An interrupted run loses at most the files since the last commit, and the next
run picks up where it stopped.

### 1d. Result

Per drive, return: files new, ok, repaired, corrupt, unreadable, unresolved,
removed and changed (from the walk), plus bytes read, elapsed time and MB/s.
Also say whether the run completed or stopped (deadline, unmount or
interrupt).

`dry_run: true` walks the drive and prints what it would do (row counts to
add, drop and reset, files and bytes to hash, and an estimate at 150 MB/s).
It writes nothing.

## Component 2: the `scrub` CLI command (`cli.rb`)

```
easy_sync scrub [NAME...] [--all] [--for DURATION] [--dry-run] [--no-keep-awake]
```

- **No arguments:** scrub one drive, the stalest of the mounted, non-retired
  drives (see "Staleness" below).
- **`NAME...`:** scrub the named drives in the order given. An unknown name
  or unmounted drive is an error; a retired drive is refused.
- **`--all`:** scrub every mounted, non-retired drive, stalest first, one after
  another.
- **`--for 8h`:** one wall-clock deadline for the whole invocation (accept
  `m`, `h` and `d`). With no flag, it runs to completion.
- Hold `RunLock` for the whole run. `sync` and `scrub` never overlap: they
  share the manifest, and sync's refetch step reads the flags. Change the
  `AlreadyRunning` message from "another easy_sync sync" to "another
  easy_sync run".
- Keep the Mac awake exactly as `sync` does (`KeepAwake`, honouring
  `keep_awake` and `--no-keep-awake`).
- Write output to a log file too, through `RunLog`. Give `RunLog.open` a
  `prefix:` argument (default `'sync'`) and prune each prefix separately, so
  that `scrub-*.log` files never push out `sync-*.log` files.
- Exit with a non-zero status if any file ends the run `corrupt`,
  `unreadable` or `unresolved`.
- Add a line to `USAGE`, and a README section.

**Staleness.** A drive's `scrubbed_through` is the oldest `verified_at`
across its `ok` rows. It is NULL if any `ok` row has a NULL digest, or if the
drive has no `ok` rows. This is the moment since which every healthy file on
the drive has been checked. Flagged and `unresolved` rows are left out: the
hash queue skips them, so their `verified_at` never advances, and counting
them would pin the drive as stalest (and overdue) forever. They show up as
findings instead. Findings on a retired drive are not reported, since
`scrub` refuses retired drives and could never clear them.

- To pick drives: order by `scrubbed_through` ascending, NULLs first, ties
  broken by `friendly_name`.
- A drive is overdue if `scrubbed_through` is NULL or older than
  `scrub_stale_days`, and it has at least one folder with `last_synced_at`
  set. An empty new drive is not overdue.

Compute this with a query; no new column is needed. Files synced since the
drive was last scrubbed don't count until the next walk adds them. They are
the least likely files to be rotten, so that is acceptable.

## Component 3: refetch in `sync`

`Mirror#refetch(source, destination, relative_paths) -> Shell result`:

```
rsync -a -I --stats --from0 --files-from=<tmpfile> <source>/ <destination>/
```

Write `<tmpfile>` NUL-separated, using `Tempfile`. Don't pass `--partial`. An
interrupted refetch should leave the old file in place, still flagged, not a
partial file.

In `Runner#sync_folder`, after the copy pass succeeds:

1. Select rows for `(target.serial_number, folder.key)` with
   `status IN ('corrupt','unreadable') AND refetched_at IS NULL`.
2. If there are none, do nothing. This is the only cost `sync` pays.
3. In dry-run, print `N flagged files would be refetched` and stop.
4. Otherwise call `refetch`. If it succeeds, set `refetched_at = now` on those
   rows and add them to the run report ("refetched N files flagged by
   scrub"). If it fails, warn and leave the rows as they are, so the next
   sync tries again.

If the copy pass fails, don't refetch. A folder skipped for any reason
(drive not mounted, source not mounted, drive full) leaves its flags as they
are.

## Component 4: reporting

- **`status`:** add one line per drive that is overdue (`never scrubbed` or
  `scrubbed N days ago`). Add a count of rows that are `corrupt`, `unreadable`
  or `unresolved`, with a pointer to `scrub`.
- **Dashboard:** show "scrubbed N days ago" or "never scrubbed" on each drive
  tile, with an overdue note in the same style as the existing unmounted note.
  **Tile colour stays SMART-only.** Add a "Scrub findings" section next to
  "Pending deletions". It lists every non-`ok` row: the drive, the path, its
  status, and "awaiting refetch", "refetched, awaiting re-check" or
  "unresolved: compare with the NAS copy".
- **`restore`:** before copying a folder back to the NAS, warn and list any
  flagged files in it. A rotted file must not quietly go back to the NAS.

## Required doc updates when this ships

- **CLAUDE.md:** replace the integrity bullets under "Open items" with a short
  description of `scrub`. The invariant "only `Purger` deletes" stays as it
  is. Add: "refetch overwrites flagged files via `rsync -I`; `scrub` is
  read-only on the drive."
- **README:** document the `scrub` command and the `scrub_stale_days` config
  key. Add `scrub_stale_days: 30` to the defaults in `Config`.

## Tests

Specs use real files under `temp_dir` for the walk and the hashing, since
nothing shells out there. rsync (the refetch) and drive detection go through
`FakeShell` and the existing `VolumeInfo` fakes. To simulate rot in a spec,
overwrite one byte and then put the mtime back with `File.utime`, so size
and mtime are unchanged.

Scrubber:
- The first run gives every file a baseline. A second run with no changes
  reports all files as `ok` and hashes nothing new.
- Rot (one byte changed, mtime restored) → `corrupt`, and the digest is not
  changed.
- A file changed legitimately (new mtime) → reset and re-baselined, not
  `corrupt`.
- File deleted → row removed. New file added → row added.
- Folder reassigned to another drive → the old drive's rows are removed on
  the next scrub of the old drive.
- An `exclude_folders` match (e.g. `.DS_Store`) is never added. Symlinks are
  skipped.
- Frontier order: refetched rows first, then NULL digests, then oldest
  `verified_at`.
- The deadline stops the run between files, and the next run continues from
  where it stopped.
- Marker disappears mid-run → stops, and the row being processed is untouched.
- `Errno::EIO` (stub the read) → `unreadable`.
- A refetched file that matches its baseline → `ok` (repaired). One that
  still differs → `unresolved`, and sync never refetches it again.
- Dry-run leaves the manifest unchanged. Compare a full dump of
  `file_checksums` from before and after. Asserting "no error" is not
  enough (see CLAUDE.md on the dry-run incident).

CLI:
- With no arguments it picks the stalest drive, and a drive that was never
  scrubbed beats every other drive.
- `--all` goes through the drives stalest first. Named drives run in the
  order given. A retired drive is refused.
- A second process is blocked by `RunLock`.
- The exit status is non-zero when there are findings.

Sync refetch:
- A flagged row causes exactly one `rsync -a -I ... --files-from` call after
  the copy pass, and `refetched_at` is set.
- No flagged rows → no extra rsync call.
- The copy pass fails → no refetch, and the flags are unchanged.
- The refetch fails → `refetched_at` stays NULL.
- Dry-run → no refetch call, and a "would refetch" line is printed.

## Verify on real hardware before merging

Use the `jbod-test` drives with a scratch `--config` (see CLAUDE.md):

1. Sync a small source tree, then `scrub` it. Every file should get a baseline.
2. Corrupt one file on the drive:
   `printf '\xff' | dd of=FILE bs=1 seek=1000 conv=notrunc`, then
   `touch -r COPY_OF_ORIGINAL FILE`.
3. `scrub` → it should report CORRUPT and exit non-zero.
4. `sync` → it should report "refetched 1 file". Check that the drive copy is
   byte-identical to the NAS copy again (`cmp`).
5. `scrub` → it should report the file as repaired.
6. Unplug the drive during a scrub. It should stop cleanly, and the next run
   should pick up where it stopped.
7. Record the measured scrub MB/s for one real fleet drive in this doc. That
   checks the ~200 MB/s estimate and shows whether `F_NOCACHE` took effect:
   a spinning drive that reads at GB/s means the flag didn't take.

### Results (2026-09-21, all seven steps passed)

1. Synced 4 files (200 MB) to `jbod-test-1`; `scrub` gave all 4 a baseline.
   It read at **2,084 MB/s**: served from the page cache, not the drive.
   `F_NOCACHE` does not evict pages already cached (it only stops new ones
   being added), and a just-synced file is exactly that case. Fixed by adding
   `Jbod::PageCache.evict`; the same files, deliberately made hot in the
   cache first, then scrubbed at **145 MB/s**.
2–3. One byte flipped at offset 1000, mtime restored: `scrub` reported
   1 CORRUPT, exited 1, digest kept.
4. `sync --dry-run` said "1 flagged file would be refetched" and wrote
   nothing; `sync` refetched it, and `cmp` against the NAS copy was
   identical (size and mtime unchanged).
5. `scrub` reported 1 repaired; every row back to `ok` with flags cleared.
6. Cable pulled mid-scrub of a 52 GB folder: the run stopped cleanly as
   "unmounted" (no hang, no crash), the file being read was left untouched
   (not flagged unreadable), and the 2 files already hashed kept their
   baselines (committed on exit). After replugging, the next `scrub` started
   with exactly the file that was interrupted. Found and fixed: the log said
   "ran to completion" after an early stop; it now says "stopped early".
7. Scrub speed, cold reads:

   | drive | interface | MB/s | read |
   |---|---|---|---|
   | `backup-01-8tb` (fleet, spinning) | SATA in the ThunderBay 8 | **201.4** | 35.7 GB (`--for 2m`) |
   | `jbod-test-1` | USB | 151.7 | 52.3 GB |

   201 MB/s matches the ~200 MB/s estimate, so the full-fleet timings in
   "Decisions" stand. `--for` also stopped correctly on real hardware; with
   ~9 GB movie files, a 2-minute limit ran about 3 minutes, since a file
   already being hashed always finishes.

## Separate and smaller: warn before Backblaze drops a drive

This is not part of this feature. Build it first if there is time. Backblaze
Personal drops a drive from the current backup after 30 days disconnected,
although version history keeps it for a year. `drives.last_seen_at` already
records when each drive was last mounted. Warn in `status` and on the
dashboard when a drive reaches 21 days, which leaves 9 days to act.
