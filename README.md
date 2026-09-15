easy_sync
=========

Backs up a NAS onto a set of independent drives, one folder at a time.

The drives are plain APFS volumes of different sizes, each used to the full, no
RAID. `easy_sync` decides which drive each folder lives on, mirrors it there with
`rsync`, remembers the placement in a SQLite manifest, waits out a grace period
before deleting anything, and writes an HTML dashboard with each drive's SMART
health. One folder always lives whole on one drive; `easy_sync restore` copies
folders back the other way, onto the NAS, when you need to repopulate it (see
"Restoring the NAS" below).

**macOS only.** It leans on `diskutil` for APFS volume identity and lock state
and on `caffeinate` to keep the Mac awake, so it needs macOS 10.13 High Sierra
or later (the first release with APFS on external drives). It is developed and
tested on macOS 26. Also needed: Ruby 3.3 or newer and rsync 3.0 or newer
(`brew install rsync`; the copy macOS ships is too old). `smartctl`
(`brew install smartmontools`) is optional and adds drive health.

Quick start
-----------

    gem install easy_sync

    easy_sync add-source /Volumes/tv                    # once per NAS share, mounted on the Mac
    easy_sync add-source /Volumes/movies
    easy_sync register-drive /Volumes/backup-01-3tb     # once per drive, while mounted
    easy_sync plan --apply           # measures each share, writes split-or-whole for each
    easy_sync sync --dry-run         # what would be placed and copied, nothing written
    easy_sync sync                   # the real thing
    open ~/.easy_sync/dashboard.html

Mount and unlock the drives yourself first; the tool never unlocks anything.

Configuration
-------------

The first command you run, even a bare `easy_sync`, creates
`~/.easy_sync/config.yml`. You don't need to edit it: `add-source`,
`remove-source` and `plan --apply` maintain it for you, and `sources` lists it.
The file stays readable and commented if you want to change the other settings
by hand:

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
:reserve: "2gb"                         # headroom placement always leaves on every drive
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


Drives
------

Any enclosure works as long as each drive mounts as its own independent APFS
volume rather than a RAID array — a multi-bay Thunderbolt dock like the
[OWC ThunderBay 8](https://www.owc.com/solutions/thunderbay-8) run in JBOD
("just a bunch of disks") mode, one volume per bay with no SoftRAID array
across them, is a natural fit for a fleet that grows one drive at a time.

A drive's friendly name defaults to its volume name, so naming the volume
itself when you erase it (Disk Utility, or `diskutil apfs addVolume`) is
usually enough — no need for `--name`. `backup-0N-<capacity>` (sequence
number, then a size hint) is the convention used throughout this README:
`backup-01-3tb`, `backup-02-6tb`, `backup-03-8tb`, and so on. The name is
just a label for `status`, the dashboard and `replace-drive`; drives are
matched by the serial in `.easy_sync/drive.json` (see below), never by name
or mount path, so renaming a volume later is safe. To change the label
easy_sync itself uses, without touching the volume: `easy_sync rename-drive
OLD NEW`; naming NEW after another registered drive swaps the two instead of
erroring, done as one transaction so you never have to pick a temporary name
yourself. It never renames the actual macOS volume (the tool never mutates
disk state, the same way it never unlocks one) — it prints the `diskutil
rename` command to run yourself if you want that to match too.

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

A new folder goes to the mounted drive with the most free space, if it fits
while leaving `reserve` (2 GB by default) untouched for APFS metadata, the
drive's `.easy_sync/` copies and rsync's temporary files. A folder with no real
files on the NAS (a show folder left holding only a `.DS_Store`) is not placed;
the run says so. Once placed, a folder never moves: there is no rebalancing. To move one by hand,
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

It flags any share whose current setting disagrees, and `--apply` writes the
recommendations to the config. Without `--apply` it reads only. Name one or
more shares (by folder name or full path, e.g. `easy_sync plan pro`) to judge
just those instead of measuring everything.

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

Replacing or upgrading a drive
------------------------------

Three situations, one command each. In every case the new drive is registered
first, and the sync afterwards does the copying.

**1. Upgrading a drive, or replacing one that is failing but still reads**
(the dashboard shows it amber). Both drives mounted:

    easy_sync register-drive /Volumes/backup-08-12tb
    easy_sync replace-drive backup-04-8tb --to backup-08-12tb --copy
    easy_sync sync

`--copy` copies the old drive's contents straight onto the new one over the
local bus, far faster than pulling them from the NAS again. Every folder is then
recorded as living on the new drive and the old drive is retired. The sync only
verifies each folder against the NAS. If the copy fails, nothing is changed.

**2. Replacing a drive that is dead** (nothing to copy from):

    easy_sync register-drive /Volumes/backup-08-12tb
    easy_sync replace-drive backup-04-8tb --to backup-08-12tb
    easy_sync sync

The folders are recorded on the new drive and the sync copies every one of them
from the NAS. That takes as long as the first sync did for those folders.

**3. Retiring a drive with no replacement, or a smaller one:**

    easy_sync replace-drive backup-04-8tb
    easy_sync sync

The old drive's folders are forgotten. The sync places each one afresh across
whatever drives are mounted, by the usual most-free-space rule, and copies it
from the NAS.

Afterwards, in all three cases:

    easy_sync status                 # the retired drive is listed at the end
    easy_sync history "tv/Show Name" # still shows the drive it used to live on

A retired drive is never placed on or written to again, even if it turns up
mounted.

Restoring the NAS
------------------

If a share gets wiped, reformatted, or you're rebuilding the NAS from
scratch, `restore` copies folders back the other way: from wherever each one
currently lives on a drive, onto its NAS share. Unlike `sync`, it **never
deletes anything** — it only adds and updates files on the NAS, so restoring
onto a share that already has some files on it (a partial wipe, a share you
rebuilt by hand) is safe.

    easy_sync restore "tv/Breaking Bad"   # one folder
    easy_sync restore tv                  # every folder placed under the tv share
    easy_sync restore --all               # everything in the manifest
    easy_sync restore tv --dry-run        # show what rsync would do first

Because folders for one share can be spread across several drives (unlike
the single Drobo volume this replaced), a restore plugs in and pulls from
whichever drives are mounted; a folder whose drive isn't mounted yet is
skipped with a warning, and running `restore` again once that drive is
plugged in picks it up. It needs the share's `:sources:` entry to still
exist (`add-source` it again first if you'd removed it) so it knows where on
the NAS each folder belongs. A real restore takes the same lock a `sync`
does, so the two never run at the same time; `--dry-run` doesn't need it.

Restoring a single file or folder you know the location of is still just
browsing `/Volumes/<drive>/<folder>` in the Finder — `restore` is for when
you want the tool to find and reassemble more than that.

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
    easy_sync clean                 # remove excluded junk from the drives now, no waiting

Entries whose name matches `exclude_folders` (a `#recycle` copied before the
exclusion existed, stray `.DS_Store` files) are never legitimately part of a
backup, so `clean` removes them from every placed folder on every mounted drive
immediately. `--dry-run` lists them first.

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

The header says how many folders the NAS holds, how many are backed up and,
in red, how many are **not**, because no mounted drive has room. That is the
one number that matters, so it also raises an alert at the top and a "Not
backed up" list under Folders, with each folder's size. Every run decides all
placements before it copies anything, so this picture is complete even if the
copy phase is interrupted.

Folders are grouped by share so thousands of them stay readable: each drive tile
shows one line per share with a count and total size, and the folders table has
a collapsible section per share with a "Needs attention" list on top for
anything failed, full, missing or unmounted. Every share starts collapsed;
only "Needs attention" starts open. Pending and completed deletions,
placement history and recent runs follow.

Commands
--------

| command | does |
|---|---|
| `add-source PATH [--split \| --whole]` | add a NAS share; the split setting is inferred unless given |
| `remove-source PATH` | stop backing up a share (drives untouched) |
| `sources` | list the configured shares and whether each is mounted |
| `sync [--dry-run] [--no-purge] [--no-keep-awake]` | mirror the shares onto the drives |
| `register-drive MOUNT [--name N] [--serial S]` | add a mounted drive |
| `replace-drive OLD [--to NEW] [--copy]` | retire a drive, handing its folders to NEW (or to the next sync) |
| `restore FOLDER\|SHARE [...] \| --all [--dry-run]` | copy folders back onto the NAS from wherever they live (reverse of `sync`; never deletes) |
| `plan [SHARE ...] [--largest-drive 8tb] [--apply]` | measure each share (or just those named) and recommend split or whole; `--apply` writes it |
| `status` | whether a sync is running (and for how long), drives, health and folders, in the terminal |
| `pending` | deletion candidates and their expiry dates |
| `clean [--dry-run]` | remove excluded junk from the drives now, without waiting |
| `history [FOLDER]` | where a folder has lived |
| `reassign FOLDER DRIVE [--note TEXT]` | record a move you made by hand (moves no data) |
| `rename-drive OLD NEW` | relabel a drive, or swap two drives' names; the manifest only, never the volume |
| `dashboard` | regenerate the HTML report only |

`--config PATH` goes before the command.

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
| `drives` | serial (PK), name, capacity, added date, volume UUID, last seen usage, SMART status and detail, retired date |
| `folders` | folder path (PK), drive serial, size, assigned and last-synced times, last status |
| `placement_history` | every `assigned`, `reassigned` and `removed` event |
| `sync_runs` | one row per rsync run: exit status and `--stats` byte counts |
| `pending_deletions` | paths gone from the NAS, first seen and runs confirmed |
| `source_inventory` | every folder seen on the NAS last run: placed, not backed up, or empty |
| `deletions` | audit log of everything actually removed from a drive |

Development
-----------

    bundle install
    bundle exec rake            # RSpec; every external call is faked, no drives or rsync needed
    bundle exec rake install    # build the gem from this checkout and install it locally
    bundle exec rake release    # tag the version and push it to rubygems.org

Version 2 removed the original snapshot mode (dated hard-linked snapshots of one
directory). It lives on in the 1.x tags.
