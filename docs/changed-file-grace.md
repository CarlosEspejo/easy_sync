# Changed-file grace period (designed, not built)

## The gap

A mirror keeps one copy. If a file is corrupted or encrypted on the NAS, the
next sync faithfully copies the damage over the good backup. The deletion grace
period protects against removal, not modification. Snapshots on the Synology
are the first answer; this is the second, for people who want it in the backup.

## Design

Extend the existing grace-period model from "deleted files" to "replaced files".

1. **Copy pass keeps the old version.** Add to `Mirror#command`:
   `--backup --backup-dir=<drive>/.easy_sync/replaced/<run timestamp>/<folder key>`
   With `-a --backup`, rsync moves each file it is about to overwrite (or that
   the deletion probe would remove) into the backup dir, preserving the relative
   path. Nothing extra is walked; rsync already knows which files change.
   Note the path is per drive, so the replaced copies sit next to the data they
   came from and travel with the drive.

2. **Record what was parked.** rsync's `--itemize-changes` output already lists
   updated files (`>f.st......` etc.). After the copy pass, `Mirror` returns a
   `replaced` list the way it returns `extraneous`. `Runner` writes one row per
   file to a new `replaced_files` table: folder_path, relative_path, run
   timestamp, backup path, size. A whole folder that goes away is already
   handled by the deletion flow; do not park it twice.

3. **Purge on the same clock.** `Purger` gets a second sweep: delete every
   `.easy_sync/replaced/<timestamp>/` directory older than `grace_days` (the
   timestamp is in the path, so no per-file state is needed) and drop its rows.
   `grace_runs` does not apply; age alone is right for parked files.

4. **Restore is manual and obvious.** `easy_sync replaced [FOLDER]` lists what
   is parked and where; restoring is copying the file back on the NAS.
   The dashboard gets a "Replaced recently" section beside "Pending deletions".

5. **Space.** Parked files count against the drive. Show the parked total per
   drive on its tile, and let `plan`/placement subtract it from free space.
   Config: `keep_replaced_days` (default = grace_days) and `park_replaced: true`.

## Edge cases to test

- A file that changes on every run (a live log) parks a copy every run; cap by
  age, not count, and say so in the README.
- `--backup` with `--delete-excluded` in the probe: the probe is `-n`, so it
  never parks anything; only the copy pass does.
- Interrupted run: rsync moves the old file into the backup dir before writing
  the new one, so an interrupted copy leaves the old version parked and the new
  one partial; the next run overwrites the partial. Verify with a real Ctrl-C.
- Disk full while parking: rsync fails the file; treat as the existing
  "drive full" status.
