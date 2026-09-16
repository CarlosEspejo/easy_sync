# Integrity scan (designed, not built)

## The gap

rsync verifies data in flight — a transfer that finishes without error wrote
what the source sent. What it does not do is notice that a file written
correctly a year ago has rotted since. The next sync's quick check compares
size and mtime only, so a flipped bit on a drive matches and is skipped
forever. APFS checksums metadata, not file contents, so the filesystem will
not catch it either. Nothing in easy_sync currently answers "is what's on the
drive still what we wrote?"

`--checksum` answers it by re-reading both sides every run, which is the wrong
trade at 35 TB behind one SMB link.

## Why this is load-bearing, not a nicety

**The offsite backup is taken from the drives, not from the NAS.** That single
fact is what justifies the whole feature. A rotted file on a drive is seen by
the offsite client as a changed file and uploaded, so the corruption
propagates to the last copy standing. The NAS still holds the good version,
but nothing is looking, and nothing tells you to go get it.

It also sets a deadline that has nothing to do with how fast bit rot happens:
**a full verify pass must complete faster than the offsite service ages out
the last good version.** Measured: retention is 1 year (Backblaze Personal)
against a ~5 month sweep, so this is satisfied comfortably — see the budget
section. It would stop being satisfied immediately if the plan ever dropped to
30-day history.

### The bigger offsite risk is not rot at all

**Backblaze Personal drops a drive's data from the current backup if that drive
has not been connected in 30 days.** Verified directly: the old Drobo volume is
absent from today's backup but still present when browsing back to September
2025. So the 30-day rule removes it from the *live* set while version history
keeps it for the retention window — roughly a year to notice and recover, not
instant loss. It is still a hole in offsite coverage, and still silent, but it
is a countdown rather than a cliff.

This is cheaper to defend than anything else in this document, and the data
already exists — `drives.last_seen_at` is written on every sync. A drive
approaching the window should be called out in `status` and on the dashboard
well before it lapses (say at 21 days, leaving nine to act), the same way an
unmounted drive already gets a note. No new tables, no scanning, no hashing.

Do this before building the scan. It protects more of the backup for a tiny
fraction of the effort.

## What covers what

- **NAS (Btrfs, with redundancy):** covered. Synology's monthly data scrubbing
  verifies checksums and self-heals from parity. Rot on the source is detected
  and repaired without easy_sync involved. (Without redundancy it detects but
  cannot repair; reads of the bad file then return an I/O error, so rsync fails
  loudly rather than copying garbage.)
- **Backup drives (APFS, single, no redundancy):** uncovered by anything. APFS
  checksums metadata, not contents. This is the entire gap.
- **A Btrfs repair never propagates outward.** The repair restores the original
  bytes at the block layer without touching size or mtime, so rsync's quick
  check skips the file forever. A NAS fix does not reach the drives on its own.

## Measured (rsync 3.5.0, homebrew, on the M-series Mac)

These are the facts the design rests on. Re-check them if rsync changes.

- **rsync already computes a per-file checksum on every ordinary copy and will
  print it for free.** `--out-format='%i %C %l %n'` keeps the itemize flags
  `Mirror` already parses and appends checksum, size, name. No `--checksum`, no
  extra read.
- **The value is stable across sessions** — identical over three separate runs
  and unaffected by `--checksum-seed`. It is therefore usable as a stored
  baseline. (Worth re-testing on any rsync upgrade; this is not documented
  behaviour.)
- **Default is xxh128**, which Ruby stdlib cannot reproduce.
  `--checksum-choice=md5` yields a real MD5 (matches `md5 -q`).
- **Only transferred files emit `%C`.** Skipped files print nothing.
- Digest throughput: **SHA-256 2514 MB/s, SHA-1 2486, MD5 763.** Apple Silicon
  accelerates SHA, not MD5. All exceed any USB read, so the disk is the
  bottleneck, never the hash.
- Forcing md5 halves rsync's *local* copy ceiling (800 MB: 0.87s → 1.84s).
  Irrelevant over SMB; it would slow `replace-drive --copy`.
- SMB metadata is very slow: a shallow `ls` plus one file read on `/Volumes/tv`
  did not return in two minutes. Any design that re-walks the NAS pays this.

## Why not compare against the NAS

The obvious approach — `rsync -anc` per folder — reads all 35 TB on *both*
sides, and the side it adds is the slow one. It also cannot separate "rotted on
the drive" from "legitimately edited on the NAS since the last sync": every
changed file reads as a finding. Verifying against a stored hash instead reads
only the drive, halves the I/O, and does not need the NAS mounted at all.

## Design

Verify each drive against a hash recorded the first time the file was seen.

1. **`verify` writes every baseline. `sync` does no hashing at all.** Store one
   row per file in a new `file_checksums` table: folder_path, relative_path,
   size_bytes, mtime, algo, digest, verified_at. Rows are created by the first
   `verify` that reaches the file (trust on first use) and updated thereafter.
   Bootstrap and steady state are the same code path because there is only one
   path.

   **This is a hard constraint, not a preference — see the budget floor below.**
   An earlier draft had the sync hash each file after copying it. That adds a
   second serial read over the same bytes and costs 25–33% of sync throughput,
   which breaks the floor outright at the low end of the observed copy range.
   `sync` is the thing that must not get slower; `verify` is the thing that
   already has a budget and runs when convenient. Put the cost where the budget
   is.

   The trade is a wider trust-on-first-use window: a file copied today is not
   baselined until the frontier reaches it. Acceptable, because that file is
   freshly written and rsync verified it in flight, making it the least likely
   thing on the drive to be rotten. If the window ever does need closing, the
   fix is to overlap hashing with the *next* folder's copy — copying is
   network-bound and hashing is local-drive-bound, so they can genuinely run
   concurrently — not to put a serial hash back into the copy path.

   Not rsync's free `%C` either, and do not "optimize" your way back to it
   later. It costs no read at all, which is tempting, but it forces
   `--checksum-choice=md5`, covers only *transferred* files (so bootstrap needs
   a separate path anyway), and the algorithm is wrong: xxh128 is not a
   cryptographic hash and MD5 is broken. SHA-256 is the only option here that
   also detects deliberate modification rather than merely accidental rot. The
   fast choice and the sound choice happen to coincide — keep it that way.

2. **`easy_sync verify [DRIVE...]` is the scan.** For each mounted, non-retired
   drive: walk its folders, re-hash, compare to `file_checksums`.
   - digest differs → **corrupt**; report loudly, this is the point of the feature
   - read error → **unreadable**; same severity, different cause
   - no row → **unverified**; hash it and record (trust-on-first-use)
   - size or mtime differs from the row → **stale**, not corrupt: the file was
     legitimately re-synced. Re-hash and update the row.

   Never delete, never repair, never touch the NAS. `verify` is read-only on
   the drive and writes only to the manifest — it must be safe to run during
   anything except a sync of that same drive (take the existing run lock).

   `verify` stays read-only because the repair belongs in `sync`, where the
   source is actually available — see 3.

3. **A corrupt file is guaranteed to be replaced on the next sync.** Detection
   without replacement is worthless here: the whole reason this matters is that
   the offsite copy is taken from the drives, so a corrupt file that lingers
   keeps poisoning the backup on every upload. Finding it is only half the job.

   The obvious remedy does not work. "Just run a sync" is wrong — the corrupt
   file still matches the NAS on size and mtime, so rsync's quick check skips
   it, forever. Nor should `verify` fix it directly; the NAS may not even be
   mounted when `verify` runs.

   So `verify` **records the finding** and `sync` **acts on it**:

   - `verify` marks the row `corrupt` in `file_checksums`. That is its only
     write, and it stays read-only on the drive.
   - The next `sync` of that folder, immediately before its copy pass, deletes
     the files flagged `corrupt` on the drive. rsync then sees them missing and
     re-copies them from the NAS as ordinary new files.
   - On success, re-hash the fresh copy, set a new baseline, clear the flag.
   - If the drive is unmounted the flag simply persists; nothing is lost and the
     next sync that reaches that folder does the work.

   Deleting immediately before the copy pass is what makes this safe: the good
   copy is one rsync away, and the file being removed is one we have positively
   established is already garbage. Log every such deletion to the existing
   `deletions` audit table with a distinct reason, so a corrupt-file replacement
   is never confused with a grace-period purge.

   **This amends a standing invariant.** `Purger` is no longer the only thing
   that deletes from a drive. The new rule: *deletion is allowed either after
   `grace_days` and `grace_runs` (Purger), or for a file positively identified
   as corrupt and re-copied in the same run (refetch).* Anything else still
   never deletes. Update CLAUDE.md when this is built.

4. **Budget every run; never scan everything.** This is the part that makes it
   usable. `verified_at` drives a rolling frontier: each run verifies
   least-recently-verified first until its budget is spent.
   `--for 2h` / `--max-bytes 500gb` / `--all`. At ~200 MB/s a full 35 TB sweep
   is ~48 hours of reading; as a weekly two-hour chore that is a complete pass
   every five months or so.

   **The cadence is set by offsite retention, not by bit rot.** Rot is slow
   enough that a quarterly pass would be fine on its own merits. What actually
   binds is that the offsite copy comes from the drives: a full pass has to
   finish before the offsite service expires the last good version, or verify
   finds the corruption after the only clean copy has already aged out.

   **Measured: retention is 1 year (Backblaze Personal), sweep is ~5 months.**
   The constraint is satisfied with roughly seven months to spare, so the
   budget can be set on convenience rather than on beating a deadline. Re-check
   if the plan changes — if retention ever drops to 30 days, the sweep has to
   shorten by an order of magnitude and the whole budget story changes.

   Report the frontier age so the gap is visible: the dashboard should say how
   long ago the *least* recently verified file was checked, which is the number
   that has to stay under the retention window. An average is useless here.

5. **Report where the numbers already live.** `verify` prints a summary like
   `sync` does. The dashboard gets a per-tile "last verified" age and a
   corrupt-file list beside "Pending deletions". A drive with corrupt files is
   as important as a failing SMART status — but keep them distinct: tile colour
   still means SMART.

   Show corrupt files as **awaiting replacement**, not merely as damage, and
   keep them listed until the refetch has actually happened. A file found
   corrupt on a drive that has not been plugged in since is the case most worth
   surfacing, because the offsite copy is carrying the bad version the whole
   time. `sync` should also say plainly how many files it replaced this run.

6. **Config.** `verify_algo: sha256`, `verify_budget: "2h"`. No automatic
   verification during `sync`; it is a separate, explicitly-invoked command.

## Free follow-on once the table exists: duplicate detection

`file_checksums` makes this nearly free — group by digest, report anything with
more than one row. Worth doing because **space is the scarce resource here**:
5.4 TB of headroom, and "how much isn't backed up at all" is the headline
number on the dashboard. A byte-identical duplicate is capacity spent twice on
the same content while something else has zero copies, so every duplicate found
is potentially a folder that gets backed up instead.

Rules, consistent with everything else here:

- **Report, never delete.** Same stance as `verify`. It prints what it found.
- **The fix belongs on the NAS, not the drives.** Removing a duplicate from a
  drive just means the next sync copies it straight back. Dedupe at the source
  and let the sync propagate the result.
- Only catches *byte-identical* files. Two encodes of the same movie at
  different qualities are not duplicates by this definition and will not be
  found, which is the correct behaviour — the tool cannot know which one you
  want.
- Cheap enough to fold into the `verify` summary rather than being its own
  command, since the digests are already in hand.

## Known limitations

- **Trust on first use.** The baseline is whatever the file looked like when it
  was first hashed. A file that was already corrupt at copy time has its
  corruption enshrined as the baseline, and every later scan confirms it as
  unchanged. `verify` is structurally blind to this and always will be — do not
  design around it, just know it.

  The compensating control is on the NAS side: Btrfs scrub reports the paths it
  repaired. Any drive copy made between the rot and that repair is suspect, and
  the remedy is the same (delete the drive copy, let sync re-fetch). This is
  manual and rare — it needs a file to rot in the window between arriving on the
  NAS and its first sync. Once a file has been synced the drive copy is immune,
  because NAS rot changes neither size nor mtime and rsync will not overwrite a
  good copy with a rotted one.

- **Repair depends on the NAS.** The refetch in 3 assumes the NAS copy is good.
  That is a fair assumption — Btrfs scrub covers that side — but it is an
  assumption, and a file flagged `corrupt` on a drive whose share has since been
  `remove-source`d has no repair path at all. Report those rather than retrying
  forever.
- **A flagged file stays corrupt until its drive is next synced.** The guarantee
  is "replaced on the next sync of that folder", not "replaced immediately".
  With drives kept offline between syncs, the window is however long until you
  next plug that drive in — which is also, not coincidentally, the window in
  which the offsite copy keeps carrying the bad version.

## Alternatives considered

**SnapRAID** (snapshot parity + per-file checksums over independent drives) does
everything in this document and is mature, tested C. It is the right answer the
day parity becomes worth paying for. It is not the right answer now:

- **It will not sell you the scrub without the parity.** `snapraid sync`
  computes parity and the content/checksum file together, and the config
  requires a parity drive sized to the largest data disk. There is no
  checksums-only mode.
- **The parity drive costs 7.28 TB**, because it has to match the largest data
  drive — the 1.82 TB and 2.73 TB units cannot serve. Against 44.59 TB of fleet
  and a ~31.9 TB library, single parity leaves 37.31 TB usable and about 5.4 TB
  of headroom. Dual parity leaves 30.03 TB and **does not fit the library at
  all**.
- **Parity buys repair, and repair is the half already covered.** The NAS is
  intact; a dead drive is a `replace-drive` and a re-sync. What is missing is
  *detection*, which is the cheap half and is a hash column in a table that
  already exists.
- It is also not a backup tool — placement, fitting, grace-period deletion and
  the "what isn't backed up at all" inventory are untouched by it. This was
  never SnapRAID *or* easy_sync, only SnapRAID for this one slice.
- **It identifies drives by path, which is weaker than what we already do.**
  Its config binds a logical name to a mount point (`data d1 /mnt/disk1`); the
  name is what lands in the content file, the path is just where to look today.
  It stores a filesystem UUID per disk and errors on an unexpected change
  (`--force-uuid` overrides), but that is a tripwire, not self-correction — it
  will not work out which drive is which. On macOS with 8 hot-swappable USB
  drives that is genuinely fragile: mount order varies, a name collision
  silently becomes `/Volumes/name 1`, and a locked encrypted volume does not
  appear at all. Adopting it would mean hand-maintaining an 8-line name→path
  map and re-checking it whenever the enclosure came up differently — after
  we already solved drive identity properly by matching the serial in
  `<drive>/.easy_sync/drive.json`.

Revisit when the library comfortably fits with a spare 8 TB drive to burn. At
that point adopt SnapRAID and delete this document rather than building both.

**Comparing drive against NAS on content** (`rsync -anc`) is rejected in "Why
not compare against the NAS" above, and the offsite dependency does not change
it: it would catch the trust-on-first-use case, but at double the I/O with the
SMB side added, and every legitimately edited file reads as a finding. The
scrub report hands you the same information for free.

## Fleet, and the speed floor this must not break

**Fleet: 8 active drives, 44.59 TB** — 4 × 7.28 TB, 2 × 5.46 TB, 1 × 2.73 TB,
1 × 1.82 TB — against a library of roughly 31.9 TB (tv 17.7, movies 12.3,
synology 1.9, pro 0.04).

**There is nothing further to measure about sync speed, and no reason to.**
Sync throughput is network IO plus the one target drive being written, because
only one folder copies at a time — so per-drive benchmarking across the
enclosure tells you nothing the observed range doesn't. Observed: **50–90 MB/s**.

That gives the acceptance criterion this whole feature has to meet:

> **If the integrity work drops sync below 50 MB/s, the design failed.**

This is what rules out hashing inside the copy path (see Design 1): a serial
post-copy read costs 25–33%, which is 37.5 MB/s at the low end of the observed
range. Any future change that touches `sync` gets held to the same line.
Verification's own read speed is unconstrained by this — it has a budget and
runs when convenient, which is the entire reason the cost belongs there.

## Open question: parallelism

Verification is drive-local, so it could run one thread per drive. That does
not contradict the sequential-sync invariant — that rule is about NAS and
network contention, neither of which applies to reading local drives. Whether
it is worth it depends on whether the OWC enclosure sustains N × sequential
reads over one USB-C link, which is a thing to measure, not assume. Note this
is the one speed question the section above does *not* settle: that one is
about writing to a single target during a sync, this is about reading from
several at once during a scan.

## Edge cases to test

- A folder re-synced between verify runs: rows must go stale (size/mtime), not
  corrupt. Getting this wrong cries wolf on every changed file and the feature
  gets ignored.
- Drive unmounted, or FileVault-locked, mid-scan: stop that drive, report it,
  do not mark its unread files as anything.
- `--dry-run` must write nothing — including no `verified_at` updates.
- A file purged by grace between runs: its rows must go with it
  (`Purger`/`clear_pending` need a matching `file_checksums` delete).
- Interrupted scan (Ctrl-C): rows already verified keep their `verified_at`, so
  the next run resumes at the frontier rather than restarting.
- Retired drives are never scanned.
- Row count: ~35 TB of mostly large media is a few hundred thousand rows, tens
  of MB of SQLite. Confirm against the real fleet — if it is far larger, fall
  back to a per-folder rollup hash (one row per folder, folder-granular
  findings) rather than per-file.
- The refetch path end to end: flag a file `corrupt`, run a sync, confirm the
  drive copy is deleted, re-copied from the NAS, re-hashed, and the flag
  cleared. This is the one path the whole feature exists to enable.
- A flagged file whose folder is skipped this run (drive unmounted, source
  unmounted, drive full): the flag must survive untouched. The failure to avoid
  is a flag cleared by a sync that never actually replaced the file.
- A sync interrupted between the delete and the copy: the file is now missing
  rather than corrupt. The next sync must still re-copy it, and the flag must
  not have been cleared. Deleting and clearing the flag are not the same event.
- `--dry-run` deletes nothing and clears nothing — it should say which files it
  *would* replace, and leave every flag in place.
- Frontier age is reported as the *oldest* `verified_at`, not an average. A
  fleet that looks 90% fresh while one drive has not been touched in a year is
  precisely the failure this number exists to make visible.
