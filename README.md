easy_sync
=========

Backs up a NAS onto a set of independent drives, one folder at a time.

The drives are plain APFS volumes of different sizes, each used to the full, no
RAID. `easy_sync` decides which drive each folder lives on, mirrors it there with
`rsync`, remembers the placement in a SQLite manifest, waits out a grace period
before deleting anything, and writes an HTML dashboard with each drive's SMART
health. One folder always lives whole on one drive, so a restore is just
browsing `/Volumes/<drive>/<folder>` in the Finder.

Requires macOS, Ruby 3.3 or newer, and rsync 3.0 or newer (`brew install rsync`;
the copy macOS ships is too old). `smartctl` (`brew install smartmontools`) is
optional and adds drive health.

Quick start
-----------

    gem build easy_sync.gemspec && gem install ./easy_sync-*.gem

    easy_sync                        # first run writes ~/.easy_sync/config.yml
    $EDITOR ~/.easy_sync/config.yml  # list your shares under :sources:
    easy_sync register-drive /Volumes/backup-01-3tb     # once per drive, while mounted
    easy_sync plan                   # measures each share: split it or keep it whole?
    easy_sync sync --dry-run         # what would be placed and copied, nothing written
    easy_sync sync                   # the real thing
    open ~/.easy_sync/dashboard.html

Mount and unlock the drives yourself first; the tool never unlocks anything.

Configuration
-------------

`~/.easy_sync/config.yml`, written with comments on first run:

```yaml
:sources:                               # each NAS share, as mounted on the Mac
- :path: "/Volumes/photos"
  :split: false                         # the whole share is one unit on one drive
- :path: "/Volumes/tv"
  :split: true                          # each subfolder (show) is placed on its own
- :path: "/Volumes/movies"
  :split: true
:mount_root: "/Volumes"                 # where the backup drives appear
:manifest_path: "~/.easy_sync/manifest.sqlite3"
:dashboard_path: "~/.easy_sync/dashboard.html"
:lock_path: "~/.easy_sync/jbod.lock"    # refuses a second concurrent sync
:log_dir: "~/.easy_sync/logs"           # one log per sync run
:keep_logs: 20
:keep_awake: true                       # caffeinate for the length of a sync
:purge: true                            # delete from the drives only after...
:grace_days: 7                          # ...this many days missing on the NAS
:grace_runs: 2                          # ...confirmed on this many separate runs
:exclude_folders: ["#recycle", "@eaDir", ".DS_Store", ".sync", ".TemporaryItems", ".Trashes",
                   ".smbdelete*", ".com.apple.timemachine.supported*", ".Spotlight-V100", ".fseventsd"]
                                        # never placed, and excluded from every rsync at any depth
:rsync_args: []                         # extra arguments appended to every rsync
```

To keep a test setup apart from the real one, pass `--config PATH` before the
command or set `EASY_SYNC_CONFIG`:

    easy_sync --config ~/jbod-test.yml sync

A 1.x config (`~/.easy_syncrc.yml`, or settings nested under `:jbod:`) is still
read.

Drives
------

    easy_sync register-drive /Volumes/backup-04-8tb
    easy_sync register-drive /Volumes/backup-01-3tb --name drive-one --serial WD-WX12345678

Registering records the drive's serial, name and capacity in the manifest and
creates `.easy_sync/` at the root of the volume. The serial comes from `smartctl`
when the enclosure passes SMART through, otherwise from the APFS Volume UUID;
`--serial` overrides both.

**Drives are recognised by that folder, never by mount path.** Every run scans
the mount root and matches each drive by the serial in its `.easy_sync/drive.json`.
If macOS mounts a drive as `/Volumes/backup-02-6tb 1`, or the drives come up in
a different order, the data still goes to the right one. A volume with no marker,
or a marker the manifest doesn't know, is never written to.

After every sync each mounted drive's `.easy_sync/` also receives a fresh copy
of the manifest and the config, so any single surviving drive can rebuild the
map of where everything lives even without the Mac.

Sources and placement
---------------------

A share with `:split: false` is one unit and lands at `/Volumes/<drive>/photos`.
A share with `:split: true` is too big for one drive, so each of its subfolders
is placed independently and lands at `/Volumes/<drive>/tv/<Show Name>`.

A new folder goes to the mounted drive with the most free space, if it fits.
Once placed, a folder never moves: there is no rebalancing. To move one by hand,
copy it and then record the move with `easy_sync reassign`.

`easy_sync plan` tells you which setting each share needs. It measures every
share (seconds for thousands of single-file movie folders, minutes for a share
with hundreds of thousands of files) and judges it against the largest drive,
or against `--largest-drive 8tb` before any drive is registered:

| share is | recommendation |
|---|---|
| larger than the largest drive | must split |
| more than half the largest drive | should split: whole, it can never move and will jam its drive |
| smaller | whole is simplest |
| has loose files at its top level | must stay whole: only folders are placed |

It ends with a `:sources:` block to paste and flags any share whose current
setting disagrees. It reads only.

Only folders are placed. A loose file at the top of a split share is never
backed up; the run warns about it and the dashboard lists it until you move it
into a folder on the NAS.

A sync run
----------

    easy_sync sync                  # --dry-run previews; --no-purge skips deletions this time

1. A share whose mount point is missing or empty is skipped with a warning (a
   stale mount point left by macOS looks exactly like that). If none is
   available the run stops.
2. Each folder already in the manifest is mirrored back to its drive. If the
   drive isn't mounted the folder is skipped, and the warning says whether the
   drive is merely locked.
3. Each new folder is measured with `du`, placed, recorded, then mirrored. The
   run announces how many it has to measure and names each one as it goes.
4. Files that rsync reports as gone from the NAS are recorded (see below), and
   any that have been gone long enough are removed from the drives.
5. Drive usage and SMART health are recorded, the manifest and config are copied
   to every mounted drive, and the dashboard is regenerated.

A folder that has outgrown its drive gets a distinct "drive full" status rather
than a bare rsync error; reassign it to a roomier drive.

Deletions have a grace period
-----------------------------

rsync never deletes anything. Each folder gets a copy pass with no deletion
flags, then a read-only probe that only *reports* files on the drive that no
longer exist on the NAS. Each reported path becomes a candidate with the time it
was first seen missing and a count of the runs that confirmed it. A candidate is
removed only once it has been missing for `grace_days` **and** confirmed on
`grace_runs` separate runs, so one bad run (a half-mounted share, a
reorganisation in progress) never deletes anything. A file that reappears is
forgotten and its clock restarts. A whole folder that vanishes from a mounted
share follows the same rule; on expiry its manifest row is removed and a
`removed` entry goes into the placement history. Every removal is written to an
audit table and shown on the dashboard.

    easy_sync pending               # every candidate and when it expires

Long runs
---------

A 30 TB library over gigabit Ethernet takes three to four days the first time.

- Runs are resumable per folder: a folder interrupted mid-copy is synced again
  next time, and the copy pass never deletes, so Ctrl-C is safe.
- The Mac stays awake by itself: `sync` starts `caffeinate -i -w <its own pid>`,
  which holds off idle sleep exactly as long as the run lasts. `--no-keep-awake`
  or `:keep_awake: false` turns that off. Keep a laptop's lid open.
- Every run is logged to `~/.easy_sync/logs/sync-<timestamp>.log`: the same
  lines as the terminal, without rsync's in-place progress updates. The newest
  `keep_logs` are kept.
- Only one sync runs at a time. A second one is refused with the running PID; a
  lock left by a dead process is reclaimed automatically.

Dashboard
---------

Drive tiles are coloured by **SMART health, never by fullness**: a drive at 97%
is doing its job. Green: self-test passed, no bad-sector counters. Amber: passed,
but reallocated, pending or uncorrectable sectors (or an NVMe critical flag) are
non-zero, so the drive is starting to fail. Red: the self-test failed. Grey: the
enclosure doesn't expose SMART. Amber and red also raise an alert at the top of
the page and a warning on the terminal. Health is read on every sync and at
registration, via `smartctl` on the physical disk, falling back to `diskutil`.

Folders are grouped by share so thousands of them stay readable: each drive tile
shows one line per share with a count and total size, and the folders table has
a collapsible section per share with a "Needs attention" list on top for
anything failed, full, missing or unmounted. Pending and completed deletions,
placement history and recent runs follow.

Commands
--------

| command | does |
|---|---|
| `sync [--dry-run] [--no-purge] [--no-keep-awake]` | mirror the shares onto the drives |
| `register-drive MOUNT [--name N] [--serial S]` | add a mounted drive |
| `plan [--largest-drive 8tb]` | measure each share and recommend split or whole |
| `status` | drives, health and folders, in the terminal |
| `pending` | deletion candidates and their expiry dates |
| `history [FOLDER]` | where a folder has lived |
| `reassign FOLDER DRIVE [--note TEXT]` | record a move you made by hand (moves no data) |
| `dashboard` | regenerate the HTML report only |

`--config PATH` goes before the command. `easy_sync jbod <command>`, the 1.x
spelling, still works.

Where things live
-----------------

| on the Mac, `~/.easy_sync/` | on each drive, `<drive>/.easy_sync/` |
|---|---|
| `config.yml` | `drive.json`, the drive's identity |
| `manifest.sqlite3` | `manifest.sqlite3`, a copy as of the last sync |
| `dashboard.html` | `config.yml`, a copy as of the last sync |
| `logs/sync-*.log` | `README.txt` |
| `jbod.lock` while a sync runs | |

Manifest schema
---------------

SQLite. Timestamps are ISO 8601 UTC, sizes are bytes.

| table | holds |
|---|---|
| `drives` | serial (PK), name, capacity, added date, volume UUID, last seen usage, SMART status and detail |
| `folders` | folder path (PK), drive serial, size, assigned and last-synced times, last status |
| `placement_history` | every `assigned`, `reassigned` and `removed` event |
| `sync_runs` | one row per rsync run: exit status and `--stats` byte counts |
| `pending_deletions` | paths gone from the NAS, first seen and runs confirmed |
| `deletions` | audit log of everything actually removed from a drive |

Development
-----------

    bundle install
    bundle exec rake        # RSpec; every external call is faked, no drives or rsync needed

Version 2 removed the original snapshot mode (dated hard-linked snapshots of one
directory). It lives on in the 1.x tags.
