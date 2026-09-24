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
    easy_sync plan                   # measures each share, checks every folder fits a drive
    easy_sync sync --dry-run         # what would be placed and copied, nothing written
    easy_sync sync                   # the real thing
    open ~/.easy_sync/dashboard.html

Mount and unlock the drives yourself first; the tool never unlocks anything.

Configuration
-------------

The first command you run, even a bare `easy_sync`, creates
`~/.easy_sync/config.yml`. You don't need to edit it: `add-source` and
`remove-source` maintain it for you, and `sources` lists it.
The file stays readable and commented if you want to change the other settings
by hand:

```yaml
:sources:                               # each NAS share, as mounted on the Mac
- :path: "/Volumes/photos"
- :path: "/Volumes/tv"
- :path: "/Volumes/movies"
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
:scrub_stale_days: 30                   # a drive is overdue for `scrub` after this many days unchecked
:scrub_jobs: 4                          # `scrub --all`/named targets scrub this many drives at once by default
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

Each top-level folder of a share is placed on its own and lands at
`/Volumes/<drive>/tv/<Show Name>`. Loose files at the top of a share (not in
any folder) are backed up too, together, as one more unit that lands in
`/Volumes/<drive>/tv/` beside the folders; the dashboard lists it as
`tv (loose files)`. There is no setting to choose: this is what mergerfs and
unRAID do, and it means a share can be any size while every drive stays
readable on its own in Finder.

A new folder goes to a drive that already holds part of the same share, if it
fits there, so a share stays together on one drive for as long as that drive
has room and only spills onto another when it must. Otherwise, or for a
share's first folder, it goes to the mounted drive with the most free space.
Either way it has to fit while leaving `reserve` (2 GB by default) untouched
for APFS metadata, the drive's `.easy_sync/` copies and rsync's temporary
files. A folder with no real files on the NAS (a show folder left holding only
a `.DS_Store`) is not placed; the run says so.

Once placed, a folder never moves on its own: there is no automatic
rebalancing. Moving data between drives costs time, needs both drives
connected, and makes the offsite backup (Backblaze, taken from the drives)
upload it all again, so it only happens when you ask. To move a folder, or
every folder of a share, run `easy_sync reassign FOLDER|SHARE DRIVE --copy`:
it copies drive-to-drive (much faster than the NAS), and the next sync only
confirms the copy. The old copy is removed later, after the grace period (see
"Deletions have a grace period" below).

`easy_sync plan` measures every share (seconds for thousands of single-file
movie folders, minutes for a share with hundreds of thousands of files) and
warns about any single folder that is bigger than the largest drive, which
could not be placed anywhere. Pass `--largest-drive 8tb` before any drive is
registered, and name one or more shares (by folder name or full path, e.g.
`easy_sync plan pro`) to measure just those. It only reads.

### Shares placed whole by an earlier build

Earlier builds could place a whole share as one unit (`:split: false`). A share placed
that way keeps syncing as one unit, unchanged, and `easy_sync sources` points
it out. To have it placed folder by folder from now on:

    easy_sync split synology --dry-run   # what it would do
    easy_sync split synology

This only updates the manifest; no data is copied. The share's folders are
already sitting at `/Volumes/<drive>/synology/<folder>`, exactly where the new
per-folder units expect them, so they stay on the drive they're on and the
next sync just confirms them. Pending deletions and `scrub` baselines carry
over. A folder that is on the drive but no longer on the NAS becomes an
ordinary missing folder and goes through the usual grace period. It needs the
share and the drive mounted, and a leftover `:split:` line in the config is
ignored.

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
than a bare rsync error; reassign it to a roomier drive with `easy_sync
reassign FOLDER DRIVE_NAME --copy`, which checks the target actually has room
first (`--force` skips that check) and copies it there from the full drive.
Without `--copy` only the manifest changes and the next sync copies the
folder from the NAS instead, from scratch. Either way the old, now-stale copy
left on the full drive is scheduled for cleanup the same way a file gone from
the NAS is: removed once the folder is verified synced to its new drive and
it's been that way for `grace_days` (see "Deletions have a grace period"
below) - it is not deleted immediately, so a bad reassign can still be undone
before the old copy disappears.

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

`easy_sync reassign` schedules the same kind of candidate for the copy it
leaves behind on the old drive, except its clock only starts once the folder
has been verified synced to its new drive (grace_days alone can't tell you
that) - so a folder that hasn't actually landed anywhere yet never gets its
only copy deleted. `replace-drive` is the exception: it retires the old drive
immediately, so whatever was on it is left as-is rather than tracked here.

    easy_sync pending               # every candidate and when it expires
    easy_sync clean                 # remove excluded junk from the drives now, no waiting

Entries whose name matches `exclude_folders` (a `#recycle` copied before the
exclusion existed, stray `.DS_Store` files) are never legitimately part of a
backup, so `clean` removes them from every placed folder on every mounted drive
immediately. `--dry-run` lists them first.

Bit rot: `scrub`
-----------------

rsync only checks data while it copies it; nothing checks it again afterwards.
If a bit flips on a drive a year later, the file keeps the same size and
mtime, so rsync's quick check skips it on every future sync - the bad copy
sits there unnoticed. That matters here because **the offsite backup
(Backblaze) is taken from the drives, not from the NAS**: a rotted file gets
uploaded as a "change", and the only good copy is the one on the NAS you
don't know you need to go get.

    easy_sync scrub                 # the drive that's gone longest without a full check
    easy_sync scrub backup-04-8tb   # a specific drive
    easy_sync scrub --all           # every mounted, non-retired drive, stalest first
    easy_sync scrub --all --jobs 8  # scrub this many drives at once (default: config scrub_jobs, 4)
    easy_sync scrub --for 8h        # stop after this long; the next scrub picks up where it left off
    easy_sync scrub --dry-run       # what would be hashed, without reading or writing anything

`scrub` is read-only: it walks a drive's assigned folders to track
new/removed/legitimately-changed files, then reads each tracked file back off
the platter (bypassing the page cache) and hashes it with SHA-256, comparing
against the hash from the first time it was ever checked. Naming several
drives, or `--all`, scrubs up to `--jobs` of them at once (one thread per
drive, never two on the same one) - each drive has its own read path, so
several at a time add real throughput instead of contending with each other;
`--jobs 1` scrubs them one at a time instead. A mismatch is reported as
**corrupt**; a read error as
**unreadable**. Nothing on the drive is ever touched - repair happens the
other way around, in `sync`: once a folder's normal copy pass succeeds, any
files `scrub` flagged for it are re-copied from the NAS with `rsync -I`
(ignoring the quick check that let rot go unnoticed the first time),
overwriting the bad copy. `scrub`'s next pass re-hashes a refetched file; a
match goes back to `ok` ("repaired"), a mismatch becomes **unresolved** and is
never refetched again automatically - it needs a look by hand, comparing
against the NAS copy. `restore` warns and lists any flagged files in a folder
before copying it back to the NAS, so a rotted file never quietly overwrites
a good one there.

A drive is overdue once it's gone `scrub_stale_days` (30 by default, matching
how long Backblaze keeps a disconnected drive in the *current* backup) since
its last full check; `status` and the dashboard say so, and the dashboard
lists every outstanding finding. `scrub` takes the same lock a `sync` does, so
the two never run at the same time - connect the drives, run `scrub --all`,
and leave it; a full pass over the whole fleet takes a while (SHA-256 itself
runs at gigabytes/second, so a spinning drive's read speed is the limit, not
the hashing).

Drive speed: `benchmark`
------------------------

A drive whose write or read speed is falling can be on its way out before
SMART says anything. `benchmark` measures it so it can be tracked:

    easy_sync benchmark                  # the drive benchmarked longest ago (never, first)
    easy_sync benchmark backup-04-8tb    # a specific drive
    easy_sync benchmark --all            # every mounted, non-retired drive, one at a time
    easy_sync benchmark --size 2gb       # a smaller test file (default 8gb)
    easy_sync benchmark --history        # the kept runs for every drive, newest first

It writes a test file of random data into the drive's `.easy_sync/` folder,
bypassing the page cache and timing the closing `fsync`, reads it back
straight off the platter, and deletes it (also on Ctrl-C or an error).
Nothing else on the drive is touched. The last 25 runs per drive are kept and
each new one is compared with the median of the drive's earlier runs. Once
there are 3 earlier runs, a result more than 15% below that median is
flagged **SLOWER** and the command exits 1. Runs normally vary by about 7%, so
re-run before worrying. A drive that has filled up since writes to slower
inner tracks, so each run also records how full the drive was.

Drives are measured one at a time: several at once would share the
enclosure and skew each other. A drive without room for the test file plus
`reserve` is skipped. `benchmark` takes the same lock as `sync` and `scrub`,
so it never measures a drive that something else is using. How to read the
numbers, and the baselines they're compared with: docs/performance.md.

Long runs
---------

A 30 TB library over gigabit Ethernet takes three to four days the first time.

- Runs are resumable per folder: a folder interrupted mid-copy is synced again
  next time, and the copy pass never deletes, so Ctrl-C is safe.
- The Mac stays awake by itself: `sync` starts `caffeinate -i -w <its own pid>`,
  which holds off idle sleep exactly as long as the run lasts. `--no-keep-awake`
  or `:keep_awake: false` turns that off. Keep a laptop's lid open.
- Every run is logged to `~/.easy_sync/logs/sync-<timestamp>.log` (`scrub` gets
  its own `scrub-<timestamp>.log`, pruned separately): the same lines as the
  terminal, without rsync's in-place progress updates. The newest `keep_logs`
  of each are kept.
- Only one sync or scrub runs at a time - they share a lock. A second one is
  refused with the running PID; a lock left by a dead process is reclaimed
  automatically.

Dashboard
---------

Drive tiles are coloured by **SMART health, never by fullness**: a drive at 97%
is doing its job. Green: self-test passed, no bad-sector counters. Amber: passed,
but reallocated, pending or uncorrectable sectors (or an NVMe critical flag) are
non-zero *and growing*, so the drive is starting to fail. Blue: reallocated
sectors are non-zero but haven't grown since they were first seen (or since the
last `verify-drive` checkpoint) - old, stable wear rather than an active
failure in progress; pending/uncorrectable sectors, media errors, or a critical
flag always stay amber regardless of trend. Red: the self-test failed. Grey: the
enclosure doesn't expose SMART. Amber and red also raise an alert at the top of
the page and a warning on the terminal; blue does not. Health is read on every
sync and at registration, via `smartctl` on the physical disk, falling back to
`diskutil`; every read's reallocated-sector count is kept in `smart_checks` so
growth can be told apart from a number that just sits there.

If an independent full-surface scan (SpinRite, `badblocks`, etc.) confirms a
flagged drive has zero new defects, `easy_sync verify-drive NAME [--note TEXT]`
records that as a checkpoint: future checks compare against today's count, not
whatever it was before, and an active `warning` on reallocated sectors alone
drops to the stable blue state immediately.

Each tile's "Drive details" opens its serial, model and, when `smartctl`
reports it, how long the drive has actually been powered on (SMART's
Power_On_Hours), not calendar age — a 5-year-old drive that sat on a shelf
can show far fewer hours than one bought last year and run around the clock
— plus every folder on it. A drive that isn't connected shows when it was
last seen, amber from 21 days and red from 30: Backblaze Personal drops a
drive from its current backup after 30 days disconnected.

Each tile also says "scrubbed N days ago" or "never scrubbed", with an
overdue badge once it passes `scrub_stale_days` - this never changes the
tile's colour, which stays SMART-only. A "Scrub findings" section, next to
Pending deletions, lists every file `scrub` has flagged: which drive, its
path, and whether it's awaiting refetch, refetched and awaiting re-check, or
unresolved. With nothing flagged it is a single line.

Running `easy_sync dashboard` (or `status`) while a `sync` is in progress
shows a rough estimate of time remaining, from what that run has actually
copied so far — the same estimate either command shows, worded the same way.

The page opens with one answer: a green, amber or red box headed "All 2,692
folders backed up" (or how many are **not**, because no mounted drive has
room: that is the number that matters), the last sync (when, how long, what
it copied), and a line for everything that needs you: folders not backed up,
a failing drive, folders in a bad state, a sync with failures or none for a
week, scrub findings, overdue scrubs, and a drive about to drop out of (or
already out of) Backblaze's current backup. "Nothing needs your attention"
otherwise. Every run decides all placements before it copies anything, so
the not-backed-up count is complete even if the copy phase is interrupted.

Then: the drives; "Latest sync", only the folders it actually copied or
failed on (the rest just confirmed nothing had changed); the folders,
grouped by share so thousands stay readable (each drive tile shows one line
per share, and the folders list has a collapsible section per share with
"Needs attention" and "Not backed up" on top; only those start open); scrub
findings and pending deletions, one line each when there are none; and
"Activity", one feed grouped by day: each sync run, folders placed or moved,
and what was deleted from which drive, with a batch (a first placement, a
60-folder move, a clean of `.DS_Store` files) shown as one expandable line.

Commands
--------

| command | does |
|---|---|
| `add-source PATH` | add a NAS share; each of its folders is placed on its own |
| `remove-source PATH` | stop backing up a share (drives untouched) |
| `sources` | list the configured shares and whether each is mounted |
| `sync [--dry-run] [--no-purge] [--no-keep-awake]` | mirror the shares onto the drives |
| `register-drive MOUNT [--name N] [--serial S]` | add a mounted drive |
| `replace-drive OLD [--to NEW] [--copy]` | retire a drive, handing its folders to NEW (or to the next sync) |
| `restore FOLDER\|SHARE [...] \| --all [--dry-run]` | copy folders back onto the NAS from wherever they live (reverse of `sync`; never deletes) |
| `plan [SHARE ...] [--largest-drive 8tb]` | measure each share (or just those named) and check every folder fits a drive |
| `status` | whether a sync is running (and for how long), drives, health and folders, in the terminal |
| `pending` | deletion candidates and their expiry dates |
| `clean [--dry-run]` | remove excluded junk from the drives now, without waiting |
| `scrub [NAME ...] \| --all [--jobs N] [--for DURATION] [--dry-run]` | read tracked files back off a drive and check them against their baseline; catches bit rot rsync can't see |
| `benchmark [NAME ...] \| --all [--size SIZE] [--history]` | time a drive's sequential write and read, compared with its own last 25 runs; flags one that has slowed down |
| `history [FOLDER]` | where a folder has lived |
| `reassign FOLDER\|SHARE DRIVE [--copy] [--note TEXT] [--force]` | move a folder, or every folder of a share, to another drive; `--copy` copies it drive-to-drive now instead of the next sync pulling it from the NAS; refuses a drive without room unless `--force` |
| `split SHARE [--dry-run]` | place a share that 2.0 placed whole folder by folder, on the drive it is already on; copies nothing |
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
| `logs/sync-*.log`, `logs/scrub-*.log` | `README.txt` |
| `jbod.lock` while a sync, scrub or benchmark runs | `benchmark.tmp`, only while `benchmark` runs |

Manifest schema
---------------

SQLite. Timestamps are ISO 8601 UTC, sizes are bytes.

| table | holds |
|---|---|
| `drives` | serial (PK), name, capacity, added date, volume UUID, model, last seen usage, SMART status/detail/power-on hours, retired date |
| `smart_checks` | one row per SMART read: drive serial, timestamp, reallocated-sector count, whether it's a manually verified checkpoint |
| `folders` | folder path (PK), drive serial, size, assigned and last-synced times, last status, scope (`tree`, or `root` for a share's loose top-level files) |
| `placement_history` | every `assigned`, `reassigned`, `split` and `removed` event |
| `sync_runs` | one row per folder synced: exit status, `--stats` byte counts, and the start time of the `sync` run it belonged to |
| `pending_deletions` | paths gone from the NAS (cause `missing_on_nas`, first seen and runs confirmed) or a folder's old drive after a reassign (cause `reassigned`) |
| `source_inventory` | every folder seen on the NAS last run: placed, not backed up, or empty |
| `deletions` | audit log of everything actually removed from a drive |
| `drive_benchmarks` | the last 25 `benchmark` runs per drive: when, test size, write and read MB/s, how full the drive was |
| `file_checksums` | one row per tracked file per drive: size, mtime, SHA-256 baseline, status (`ok`/`corrupt`/`unreadable`/`unresolved`), when it last failed or was refetched |

Development
-----------

    bundle install
    bundle exec rake            # RSpec; every external call is faked, no drives or rsync needed
    bundle exec rake install    # build the gem from this checkout and install it locally
    bundle exec rake release    # tag the version and push it to rubygems.org

Version 2 removed the original snapshot mode (dated hard-linked snapshots of one
directory). It lives on in the 1.x tags.
