easy_sync
=========

A small Ruby wrapper around `rsync` with two modes:

* **Snapshot mode** (the original): dated, hard-linked incremental snapshots of a
  source directory, keeping the last five.
* **JBOD mode** (new): mirrors each top-level folder from a NAS share onto one of
  several independently mounted drives, keeps a SQLite manifest of which folder
  lives where, and writes an HTML status dashboard after every run.

Requires Ruby 3.3 or newer (4.0 works) and rsync 3.0 or newer (`brew install rsync`; the copy
macOS ships is too old for the deletion reporting described below).

### Installation

    gem build easy_sync.gemspec
    gem install ./easy_sync-*.gem

### Configuration

Everything the tool keeps on the Mac lives in `~/.easy_sync/`: `config.yml`,
`manifest.sqlite3`, `dashboard.html` and the run lock. Running `easy_sync` once
writes a sample `config.yml` there (a config from the original gem at
`~/.easy_syncrc.yml` is moved into place automatically). To use
a different file (say, one that points at a couple of scratch USB drives while
you test, without touching the real one), pass `--config PATH` before the
command, or set `EASY_SYNC_CONFIG`:

    easy_sync --config ~/jbod-test.yml jbod sync
    EASY_SYNC_CONFIG=~/jbod-test.yml easy_sync jbod status

```yaml
:logging: :on
:tasks:                      # snapshot mode
- :sync_name: sample_sync
  :source: "[/example/path]"
  :destination: "[/example/path]"
  :exclude_file: "[/example/path]"
:jbod:                       # JBOD mode
  :sources:                               # each Synology share, mounted on the Mac
  - :path: "/Volumes/photos"
    :split: false                         # the whole share is one unit
  - :path: "/Volumes/tv"
    :split: true                          # each subfolder (show) is placed on its own
  - :path: "/Volumes/movies"
    :split: true
  :mount_root: "/Volumes"                 # where the backup drives appear
  :manifest_path: "~/.easy_sync/manifest.sqlite3"
  :dashboard_path: "~/.easy_sync/dashboard.html"
  :lock_path: "~/.easy_sync/jbod.lock"    # refuses a second concurrent `jbod sync`
  :keep_awake: true                       # caffeinate for the length of a sync (macOS)
  :purge: true                            # remove backed-up files once they have been gone from the NAS...
  :grace_days: 7                          # ...for at least this many days
  :grace_runs: 2                          # ...and confirmed missing on this many separate runs
  :exclude_folders: ["#recycle", "@eaDir", ".DS_Store"]
  :rsync_args: []                         # extra arguments appended to every rsync
```

### JBOD mode

The drives are plain APFS volumes, no RAID, each used at full capacity. Mount and
unlock them yourself first; the tool never tries to unlock anything.

**Register each drive once** while it is mounted:

    easy_sync jbod register-drive /Volumes/backup-04-8tb
    easy_sync jbod register-drive /Volumes/backup-01-3tb --serial WD-WX12345678   # override auto-detection

This records the drive in the manifest (serial number, name, capacity) and
creates a `.easy_sync/` folder at the root of the volume holding `drive.json`,
the drive's identity. After every sync that folder also receives a fresh copy of
the manifest and of the config, so any single surviving drive can rebuild the
map of where everything lives even if the Mac is gone.

Without `--serial`, the serial is auto-detected: `register-drive` first tries the
hardware serial via `smartctl` (a real, stable serial that survives a reformat),
resolving the volume to its physical disk itself rather than trusting `smartctl`'s
own exit status, which is inconsistent across device classes. If that doesn't
resolve — `smartctl` isn't installed, or, common for external USB enclosures, the
bridge chip doesn't pass SMART through at all — it falls back to the APFS Volume
UUID from `diskutil info`. Either way it prints which source it used.

**Drives are identified by the marker, never by mount path.** On every run the
mount root is scanned for markers and each registered drive is matched by the
serial inside it. If macOS mounts `backup-02-6tb` as `/Volumes/backup-02-6tb 1`,
or the drives come up in a different order, the data still goes to the right
drive. A volume with no marker, or a marker for an unknown serial, is never
written to.

**Sources.** Each Synology share is mounted separately on the Mac, so each one is
listed under `:sources:`. A share with `:split: false` is placed as one unit and
ends up at `/Volumes/<drive>/photos`. A share with `:split: true` is too big for
one drive, so each of its subfolders is placed independently and ends up at
`/Volumes/<drive>/tv/<Show Name>`. Either way the manifest key is the path
relative to the mount root: `photos`, `tv/Show Name`.

**Not sure whether to split a share?** `easy_sync jbod plan` measures every
configured share (one `du` per share: seconds for a few thousand single-file
movie folders, minutes for a share with hundreds of thousands of files)
and prints a recommendation against the largest drive in the fleet, or against
`--largest-drive 8tb` before any drive is registered: a share bigger than the
largest drive must be split; one over half that size should be, because a whole
share can never move and will jam its drive as it grows; a small share is
simplest whole; a share with loose files at its top level must stay whole. It
ends with a `:sources:` block ready to paste, and flags any share whose current
setting disagrees. It reads only.

Only folders are placed. A file sitting loose at the top level of a split share
(say `/Volumes/tv/stray.mkv`) is never backed up; the run warns about it and the
dashboard lists it until you move it into a folder on the NAS.

**Sync** whenever you like:

    easy_sync jbod sync             # add --dry-run to see what rsync would do

Each run:

1. Skips any share whose mount point is missing or empty (a stale mount point
   left behind by macOS looks exactly like that), and refuses to start if none
   is available.
2. Lists the folders across the available shares.
3. Folders already in the manifest are mirrored back to their assigned drive.
   There is no rebalancing, ever. If that drive is not mounted, the folder is
   skipped with a warning — one that names the drive as locked, rather than just
   "not mounted", whenever that's detectable (`diskutil apfs list` shows it as a
   FileVault volume that's connected but not unlocked).
4. A folder not yet in the manifest is measured with `du`, assigned to the
   mounted drive with the most free space (if it fits), recorded, then mirrored.
   If a folder that's already assigned has since outgrown its drive's free
   space, the sync fails with a distinct "drive full" status (rather than a
   bare rsync error) on both the terminal and the dashboard; move it to a
   roomier drive with `jbod reassign`.
5. Files that rsync reports as gone from the NAS are noted (see below), and any
   that have been gone long enough are removed from the drives.
6. Drive usage, every rsync run, and the dashboard are updated.

Measuring a new folder means a `du` over the network, which can take a while
per folder on a first run with hundreds of them; the run says how many it has
to measure up front and names each one as it goes, so it never looks hung.

Only one `jbod sync` runs at a time: a PID file at `lock_path` refuses a second
concurrent run (with a clear message naming the running PID) rather than letting
two syncs race the NAS or the manifest. A stale lock — its process no longer
running — is reclaimed automatically.

**Deletions have a grace period.** rsync itself never deletes anything. Each
folder gets a copy pass with no deletion flags, then a read-only probe
(`rsync -n --delete --itemize-changes`) that only *reports* the files on the
drive that no longer exist on the NAS. Each reported path goes into a
`pending_deletions` table with the time it was first seen missing and a count of
the runs that confirmed it. A path is removed from its drive only once it has
been missing for `grace_days` **and** confirmed on `grace_runs` separate runs,
so a single bad run (a share that was half-mounted, a reorganisation in
progress) never causes a deletion. If the file reappears on the NAS its
candidate row is dropped and the clock starts over. A whole folder that vanishes
from a mounted share follows the same policy; when it expires the folder is
removed from the drive, its manifest row is deleted, and a `removed` row goes
into the placement history. Every actual deletion is written to a `deletions`
audit table and shown on the dashboard.

**The first sync is long.** A 30 TB library over gigabit Ethernet is three to
four days. Runs are resumable per folder (a folder interrupted mid-copy is simply
synced again next time, and nothing is ever deleted by the copy), so Ctrl-C is
safe. The Mac must not sleep, so `jbod sync` keeps it awake itself: it starts
`caffeinate -i -w <its own pid>`, which holds off idle sleep exactly as long as
the sync runs and exits with it. Turn that off with `--no-keep-awake` or
`:keep_awake: false`. The display may still lock; on a laptop keep the lid open.

    easy_sync jbod pending          # what is scheduled, and when
    easy_sync jbod sync --no-purge  # sync without deleting anything this time
    easy_sync jbod sync --dry-run   # show what rsync and the purge would do

One folder always lives entirely on one drive, so restoring by hand is just a
matter of browsing `/Volumes/<drive>/<folder>`.

**Other commands:**

    easy_sync jbod status                          # drives and folders, in the terminal
    easy_sync jbod history [FOLDER]                # where has this folder lived?
    easy_sync jbod reassign FOLDER DRIVE_NAME      # record a move you made by hand (moves no data)
    easy_sync jbod pending                         # deletion candidates and their expiry dates
    easy_sync jbod plan [--largest-drive 8tb]      # split or whole? measured recommendation per share
    easy_sync jbod dashboard                       # regenerate the HTML report only

### Dashboard

Drive tiles are coloured by **SMART health, never by fullness**: a JBOD drive
sitting at 97% is doing its job. On every sync (and at registration) each
mounted drive's health is read with `smartctl -a` on its physical disk (plainly,
then through a SAT USB bridge), falling back to the one-word SMART Status from
`diskutil info`. Green means the self-assessment passed with no bad-sector
counters; amber means it passed but reallocated, pending or uncorrectable
sectors (or an NVMe critical flag) are non-zero, i.e. the drive is starting to
fail; red means the self-assessment itself failed; grey means the enclosure
doesn't expose SMART at all. Amber and red drives also get an alert at the top
of the page and a warning on the terminal, with the counters.

The HTML report groups everything by share so a library of several hundred
movie and show folders stays readable: each drive tile shows one line per share
with a folder count and total size (the full list is a click away), and the
folders table has one collapsible section per share, with a "Needs attention"
section at the top listing every folder that is not in a good state (failed,
drive full, missing on the NAS, share or drive not mounted). Shares with a
handful of folders start expanded; big ones start collapsed.

### Manifest schema

SQLite, at `manifest_path`. Timestamps are ISO 8601 UTC, sizes are bytes.

| table | purpose |
|---|---|
| `drives` | `serial_number` (PK), `friendly_name`, `capacity_bytes`, `added_date`, `volume_uuid`, last seen used/free |
| `folders` | `folder_path` (PK), `drive_serial` (FK), `size_bytes`, `assigned_at`, `last_synced_at`, `last_sync_status` |
| `placement_history` | every `assigned` / `reassigned` / `removed` event, so "where did this used to live" is always answerable |
| `sync_runs` | one row per rsync invocation with exit status and `--stats` byte counts |
| `pending_deletions` | paths rsync reports as gone from the NAS, with `first_missing_at` and `missing_runs` |
| `deletions` | audit log of everything actually removed from a drive |

### Snapshot mode

    easy_sync            # or: easy_sync snapshot

Runs each task in `:tasks`, creating `destination/YYYY-MM-DD` with
`--link-dest` against the previous snapshot and pruning to the last five dated
snapshots after a successful run.

### Development

    bundle install
    bundle exec rake        # runs the RSpec suite; no real drives or rsync needed
