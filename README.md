easy_sync
=========

A small Ruby wrapper around `rsync` with two modes:

* **Snapshot mode** (the original): dated, hard-linked incremental snapshots of a
  source directory, keeping the last five.
* **JBOD mode** (new): mirrors each top-level folder from a NAS share onto one of
  several independently mounted drives, keeps a SQLite manifest of which folder
  lives where, and writes an HTML status dashboard after every run.

Requires Ruby 3.3+ and `rsync`. Tested against Ruby 3.3 and 3.4.

### Installation

    gem build easy_sync.gemspec
    gem install ./easy_sync-*.gem

### Configuration

Running `easy_sync` once writes a sample config to `~/.easy_syncrc.yml`:

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
  :warn_threshold: 0.85                   # flag drives fuller than this
  :delete: true                           # files removed on the NAS are removed from the backup
  :exclude_folders: ["#recycle", "@eaDir", ".DS_Store"]
  :rsync_args: []                         # extra arguments appended to every rsync
```

### JBOD mode

The drives are plain APFS volumes, no RAID, each used at full capacity. Mount and
unlock them yourself first; the tool never tries to unlock anything.

**Register each drive once** while it is mounted:

    easy_sync jbod register-drive /Volumes/backup-04-8tb
    easy_sync jbod register-drive /Volumes/backup-01-3tb --serial WD-WX12345678   # e.g. from smartctl

This records the drive in the manifest (serial number, name, capacity) and writes
a small marker file, `.easy_sync_drive.json`, at the root of the volume. Without
`--serial` the APFS Volume UUID from `diskutil info` is used.

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

**Sync** whenever you like:

    easy_sync jbod sync             # add --dry-run to see what rsync would do

Each run:

1. Skips any share whose mount point is missing or empty (a stale mount point
   left behind by macOS looks exactly like that), and refuses to start if none
   is available, so a `--delete` mirror can never wipe the backups by accident.
2. Lists the folders across the available shares.
3. Folders already in the manifest are mirrored back to their assigned drive.
   There is no rebalancing, ever. If that drive is not mounted, the folder is
   skipped with a warning.
4. A folder not yet in the manifest is measured with `du`, assigned to the
   mounted drive with the most free space (if it fits), recorded, then mirrored.
5. Drive usage, every rsync run, and the dashboard are updated.

One folder always lives entirely on one drive, so restoring by hand is just a
matter of browsing `/Volumes/<drive>/<folder>`.

**Other commands:**

    easy_sync jbod status                          # drives and folders, in the terminal
    easy_sync jbod history [FOLDER]                # where has this folder lived?
    easy_sync jbod reassign FOLDER DRIVE_NAME      # record a move you made by hand (moves no data)
    easy_sync jbod dashboard                       # regenerate the HTML report only

### Manifest schema

SQLite, at `manifest_path`. Timestamps are ISO 8601 UTC, sizes are bytes.

| table | purpose |
|---|---|
| `drives` | `serial_number` (PK), `friendly_name`, `capacity_bytes`, `added_date`, `volume_uuid`, last seen used/free |
| `folders` | `folder_path` (PK), `drive_serial` (FK), `size_bytes`, `assigned_at`, `last_synced_at`, `last_sync_status` |
| `placement_history` | every `assigned` / `reassigned` / `removed` event, so "where did this used to live" is always answerable |
| `sync_runs` | one row per rsync invocation with exit status and `--stats` byte counts |

### Snapshot mode

    easy_sync            # or: easy_sync snapshot

Runs each task in `:tasks`, creating `destination/YYYY-MM-DD` with
`--link-dest` against the previous snapshot and pruning to the last five dated
snapshots after a successful run.

### Development

    bundle install
    bundle exec rake        # runs the RSpec suite; no real drives or rsync needed
