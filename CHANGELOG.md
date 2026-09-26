# Changelog

Major features only, per released version. Commit history has the rest.

## 2.0.0 (unreleased)

A rewrite. easy_sync no longer takes snapshots of one folder: it mirrors NAS
shares onto a set of independent drives (JBOD) and tracks where every folder
lives. Nothing from 0.0.x carries over; see "Breaking changes".

### Backup

- **Folder-level placement across drives.** Each top-level folder of a share
  goes to one drive, plus one unit for the share's loose top-level files. A
  share stays on one drive while it fits and spreads out only when it must.
  Placed folders never move on their own.
- **SQLite manifest** (`~/.easy_sync/manifest.sqlite3`) of drives, folders,
  sync runs and placement history, with a copy on every drive.
- **Drives matched by serial number**, never by mount path. Unknown or retired
  volumes are never written to.
- **Deletions with a grace period.** rsync never deletes; a file gone from the
  NAS is removed from its drive only after `grace_days` and `grace_runs`.
- **Ransomware tripwire** that notices a sync about to replace or remove far
  more existing files than normal. It only reports for now; enforcing it is
  opt-in (`tripwire_enforce`).
- **"Not backed up" inventory**: every folder on the NAS is shown as placed,
  not backed up (no drive has room) or empty, even when a copy is interrupted.
- **`restore`** copies folders back onto the NAS from their drives, never
  deleting anything.

### Drive health

- **SMART health** via `smartctl` (falling back to `diskutil`), with
  reallocated-sector trends so old, stable wear isn't reported as failure.
  `verify-drive` records a clean full-surface scan as a new baseline.
- **`scrub`**: bit-rot detection that reads files back off the platter and
  checks them against stored checksums, several drives at once
  (`--jobs`), within a time budget (`--for 8h`). The next sync re-copies
  flagged files.
- **`benchmark`**: each drive's write and read speed over time, flagging a
  drive that has slowed down.

### Managing drives and shares

- `add-source`, `remove-source` and `sources`: the tool writes the config.
- `register-drive`, `rename-drive`, `replace-drive`, `forget-drive`.
- `reassign` moves a folder or a whole share to another drive (`--copy`
  copies it drive-to-drive).
- `plan` measures shares and checks every folder fits a drive.
- `eject` ejects every connected drive so the enclosure can be powered off
  between syncs, and says when to connect them again for Backblaze.
- `clean` removes excluded junk (`.DS_Store`, `#recycle`, ...) from the drives.

### Reporting

- **HTML dashboard**: a one-line verdict, drive tiles coloured by SMART health
  (never by fullness), sync history, pending deletions, scrub findings and an
  activity feed.
- **`status`**: drives, health and folders in the terminal, including a
  running sync's progress and time remaining.
- A log per sync and scrub under `~/.easy_sync/logs/`.

### Safety

- `--dry-run` writes nothing, anywhere.
- One long run at a time: sync, scrub, restore, clean, benchmark and
  `reassign --copy` share a lock.
- Ctrl-C stops the running rsync cleanly, and an interrupted copy picks up
  where it left off on the next run instead of starting the file over.
- The Mac is kept awake during long runs (`caffeinate`).

### Breaking changes

- macOS only (10.13 or later); Ruby 3.3 or later; rsync 3.0 or later.
- Snapshot mode is gone.
- The config moved to `~/.easy_sync/config.yml`, and its format changed.
  `~/.easy_syncrc.yml` is not migrated.

## 0.0.5 (2014-12-28)

- Incremental rsync snapshots of a folder, keeping the last 5.
