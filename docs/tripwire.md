# Tripwire: stop a sync that would overwrite the backup wholesale (designed, not built)

## The gap

A mirror keeps one copy. If ransomware or a bad app rewrites files on the
NAS, the next `sync` copies the damage over the good backup. Nothing
covers that today:

- The deletion grace period only protects files that disappear. rsync
  still overwrites files that changed.
- `scrub` trusts the NAS. It treats a new size or mtime as a legitimate
  re-sync and makes the new hash the baseline, and its repair path fetches
  the file again from the NAS (docs/integrity-scan.md, "What is already
  covered").
- Synology snapshots and Backblaze's 1-year version history can recover
  after the fact. But Backblaze uploads from the drives, so every
  overwritten file on a drive also becomes the current version offsite.

The tripwire stops the copy *before* it starts when a run would change far
more existing files than the library ever changes normally. A media library
adds files, and now and then one is replaced (a better rip, a re-tag). It
almost never rewrites hundreds of existing files at once. Ransomware always
does.

This replaces an earlier design (keeping every replaced file on the drive
for `grace_days`). That design was dropped: Synology snapshots and
Backblaze history already cover recovery, and it cost drive space on every
run. The tripwire is cheap and prevents the damage instead of storing it.

## What counts as a change

rsync's itemized output already classifies every file. In a dry run
(`-n --itemize-changes`):

| Line | Meaning | Counts? |
|---|---|---|
| `>f+++++++++ path` | new file | no: nothing on the drive is lost |
| `>f.st...... path`, `>f..t...... path`, any other `>f` | existing file would be overwritten | **yes, replaced** |
| `*deleting path` | on the drive, gone from the NAS | **yes, missing** |
| `cd+++`, `.d..t`, symlinks, etc. | directories/metadata | no |

Missing files count as well, because most ransomware writes
`photo.jpg.locked` and deletes `photo.jpg`. That shows up as one new file
plus one deletion, with nothing replaced. Counting the deletion means a
rename counts once. Deletions are still protected by the grace period. The
tripwire just stops the new junk being copied and says why.

A file whose size and mtime stay the same is never copied by rsync's quick
check, so it can't reach the drive. Content-only ransomware that preserves
both is harmless to the backup.

## Where it runs: one probe, moved before the copy

Today each folder gets a copy pass, then a read-only deletion probe
(`Mirror#probe`, `rsync -an --itemize-changes --delete [--delete-excluded]`).
That probe's output already has every line the table above needs. The
change is to run it *before* the copy instead of after it, for every
planned folder, as a new phase between placement and copying:

1. **Phase 1 (unchanged):** measure, place, record `source_inventory`.
2. **Phase 1b, check:** for every planned folder that has synced before
   (`sync_runs` has a successful row), run the probe with `--stats` added.
   Keep per folder: replaced count, missing list (already parsed by
   `parse_extraneous`), and the files-on-drive count (see Thresholds).
   A folder placed this run has nothing on the drive yet, so it isn't checked.
3. **Decide.** Apply the thresholds below. If the whole run trips, stop:
   no copy phase and no purge. If only some folders trip, skip those and
   carry on with the rest.
4. **Phase 2, copy:** as today, minus the post-copy probe. After a
   folder's copy succeeds, feed its phase-1b missing list to
   `note_missing`. The old rule stays: a folder whose copy failed starts no
   deletion clocks.

**Cost:** the same two walks per folder as today, in a different order,
so the 50 MB/s aggregate floor (docs/performance.md) should not move. The
difference is that about 2,700 probes (~0.15 s each for an unchanged folder,
so ~7 min) now run before the first byte is copied. Verify both numbers on
the real fleet before merging.

**Staleness:** the missing list can be up to a copy phase old (days, on a
first sync) by the time it is recorded. That is harmless.
`reconcile_pending` already removes a pending deletion when the file turns
up again. A file deleted during the copy is found on the next run. Purger
still needs `grace_days` and `grace_runs`.

**Probe failure:** a folder whose check probe fails is not copied this run
(warn, status `skipped_check_failed`). Nothing can vouch for it, and a
failing probe over SMB almost always means the copy would fail too. This
is a change from today, where a failed post-copy probe only warns.

## Thresholds

Three config keys. Defaults are guesses to be tuned from real runs (see
Rollout):

    :tripwire_run_files: 500       # whole run: stop everything at this many changed files
    :tripwire_folder_files: 50     # one folder: needs at least this many changed files...
    :tripwire_folder_ratio: 0.25   # ...AND at least this share of its files on the drive

- **Files on the drive** for a folder = the NAS regular-file count from
  the probe's `--stats` ("Number of files: N (reg: R, ...)"), minus new
  files, plus missing files. No extra walk of the drive.
- **Per folder:** trips when changed ≥ `tripwire_folder_files` AND
  changed / files on drive ≥ `tripwire_folder_ratio`. The ratio stops a big
  share with a routine 60-file edit from tripping. The minimum stops a
  3-file folder with one replaced file from tripping.
- **Whole run:** trips when the sum of changed files across all checked
  folders ≥ `tripwire_run_files`. This is the check that catches ransomware
  spread across thousands of single-file movie folders, none of which
  trips on its own. Because every folder is checked before any copy
  starts, the run stops before *anything* is overwritten.
- `tripwire_run_files: 0` turns the tripwire off entirely (report-only
  logging still runs).

## When it trips

- **Tripped folder:** not copied, no deletion clocks, no refetch of scrub
  flags. `mark_folder_status(key, 'tripped')`. The trip is sticky for
  free: nothing was copied, so the next run sees the same changes and
  trips again until you accept them.
- **Tripped run:** nothing copied, **Purger does not run** (ransomware that
  deletes could otherwise ride out the grace period while you're away),
  and every planned folder is marked `tripped`. `copy_state_to_drives` and
  the dashboard write still happen, so the trip shows up.
- **Output:** per tripped folder, the counts plus up to 10 sample paths.
  Seeing `*.locked` or unreadable names is usually enough to tell ransomware
  from a re-tag. `sync` exits non-zero.
- **Dashboard:** the verdict goes red ("Sync stopped: 2,314 files would
  change on the NAS side") above everything else. The tripped folders are
  listed with their counts and samples. Store what the dashboard needs in
  a `tripwire_trips` table (run_started_at, folder_path, replaced, missing,
  files_on_drive, samples JSON, accepted_at). Add it with
  `CREATE TABLE IF NOT EXISTS`, per the manifest rule in CLAUDE.md.

## Accepting a legitimate bulk change

    easy_sync sync --accept-changes              # accept every trip this run
    easy_sync sync --accept-changes music/Jazz   # accept only these folders

The acceptance applies to that run only. It is never saved, so a later
unrelated trip still stops. `--accept-changes` with a folder that doesn't
trip is fine (no-op). The accepted trip is still recorded (`accepted_at`
set), so the dashboard's history shows that a big change went through and
who allowed it (the flag).

## Dry run

`--dry-run` runs phase 1b in full (the probes are read-only already) and
prints what would trip. Per CLAUDE.md, it writes nothing: no
`tripwire_trips` row, no folder status. Running `sync --dry-run` is how you
look before accepting.

## Rollout

1. **Report-only first.** Build the probe move and the counting, and log the
   per-folder and per-run counts on every sync, but enforce nothing
   (`tripwire_enforce: false` until step 2). Run the real fleet for a couple
   of weeks and read the largest legitimate counts. Set the defaults
   comfortably above them.
2. **Enforce.** Flip the default, and keep the report-only key for anyone
   whose library churns.

## Edge cases to test

- Ransomware-style rename across 1,000 single-file folders: no folder
  trips, the run does, nothing is copied, Purger does not run.
- One folder with 80 of 100 files replaced: that folder trips, the others
  sync, Purger runs for them.
- A share-wide re-tag of 5,000 music files: trips; `--accept-changes`
  syncs it; the following run is quiet.
- Root-files unit (`root_only`): its probe has no `--delete-excluded`, so
  subfolders are never counted as missing, same as today.
- A folder placed this run: not checked, copied normally.
- Probe fails for one folder: that folder is skipped, the rest continue.
- `--dry-run` with a trip: prints it, manifest byte-for-byte unchanged.
- Interrupted during phase 1b: nothing copied, nothing recorded beyond
  phase 1 (as today).
- Real hardware: measure phase 1b's duration and the run's aggregate MB/s
  against docs/performance.md. Then simulate ransomware on a scratch
  source (rename + rewrite a few hundred files) against `jbod-test-1`.
