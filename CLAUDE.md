# easy_sync: notes for whoever works on this next

macOS-only Ruby gem (2.0.0) that mirrors NAS shares onto independent drives.
README.md is the user-facing truth; this file is for working on the code.

## Run the suite before every push

    bundle exec rake            # ~0.3 s, 200+ examples, no drives or rsync needed

- Every external call (rsync, df, du, diskutil, smartctl, caffeinate) goes through
  `EasySync::Shell`; specs inject `FakeShell` (spec/support/fake_shell.rb) and
  register responses with `fake_shell.on(...)`. Never let a spec shell out for real.
- The suite redirects the home directory (`stub_const` on `Config::HOME_DIR` in
  spec_helper). Keep it that way: an earlier version of a test
  found the developer's real config and moved it into a temp dir that was then
  deleted. Any new default path must be derived from `HOME_DIR` at call time
  (`Config.defaults`), never at load time.
- Specs use paths under `temp_dir`, never literal `/Volumes/...` (that broke on a
  real Mac where `/Volumes` is not writable).

## Things learned on real hardware (do not re-derive)

- rsync 3.5: `--exclude=/*/` (anchored, directories only) copies only a
  source's top-level files, and a `--delete` probe with it but WITHOUT
  `--delete-excluded` never reports the destination's subdirectories, even
  ones missing from the source. That is how a share's root-files unit lives
  in the same directory as the share's per-folder units.
- rsync 3.5 with `--delete --max-delete=0` does NOT name the files it skips; it
  prints "N skipped" and exits 25. Deletions are found with a separate read-only
  probe: `rsync -an --itemize-changes --delete --delete-excluded`.
- smartctl's exit status is inconsistent (exit 0 with "not supported" on some
  devices, 2 on others); parse output, never trust the code. USB bridges often
  hide SMART entirely: that is the 'unknown' state, not an error.
- `diskutil apfs list` shows a locked volume by name with "FileVault: Yes (Locked)"
  and "Mount Point: Not Mounted"; the Name and FileVault lines are several lines
  apart. `diskutil apfs lockVolume/unlockVolume` accept the volume name.
- Physical disk for smartctl: `diskutil info <mount>` -> "Part of Whole" ->
  `diskutil info <that>` -> "APFS Physical Store".
- `caffeinate -i -w <pid>` exits on its own when the pid does; spawn it detached.
- The real `~/.easy_sync/manifest.sqlite3` is stamped `user_version` 5 (left over
  from pre-2.0 builds) although 2.0's schema counts from 1. Add columns by
  checking `PRAGMA table_info`, never by comparing version numbers: a
  version-gated `ALTER TABLE` was skipped on the real manifest and crashed the
  first sync after it (`no such column: model`).
- `du` over SMB: seconds for thousands of single-file movie folders, minutes for a
  share with hundreds of thousands of files. rsync's read-only walk of an
  unchanged folder is ~0.15 s.
- Headless Chrome refuses windows narrower than ~500 px; render phone widths
  inside a 400 px iframe.
- `F_NOCACHE` does NOT make a read skip the page cache for pages already in
  it; it only stops the read adding new ones. A just-synced file scrubbed at
  2 GB/s from a USB drive until `Jbod::PageCache.evict` (mmap +
  `msync(MS_SYNC|MS_INVALIDATE)`, via Fiddle) dropped its pages first. Any
  "read it off the platter" code needs both. Fiddle is a bundled gem in Ruby
  4.0, so it's declared in the gemspec.
- Pulling a drive's cable mid-read: the marker file vanishes and reads fail;
  scrub stops as "unmounted" without flagging the in-flight file. A
  FileVault test drive came back mounted and unlocked on replug.
- Scrub reads a fleet drive (spinning SATA, ThunderBay) at ~201 MB/s;
  `jbod-test-1` (USB) at ~150 MB/s.

- Forwarding a signal to a child process (Ctrl-C during a copy) must signal its
  whole process group, not just its pid: `Open3.popen2e(*argv, pgroup: true)`,
  then `Process.kill('INT', -wait.pid)` (negative pid = the group). Signalling
  only the child's own pid left rsync's helper processes running and Ruby
  blocked waiting on them; a plain `sh -c '...; sleep N'` child in specs won't
  even forward the signal to its own `sleep` without this.

## Invariants (never break these)

- rsync never deletes. Only `Purger` deletes, only after `grace_days` AND
  `grace_runs`, only inside the folder's own destination on a mounted drive.
  It never `rm_rf`s a whole folder that overlaps a live folder on the same
  drive (one below it, or a `tree` folder above it), and a `root` folder's
  whole-folder purge removes only its top-level files.
  `sync`'s refetch overwrites flagged files via `rsync -I`; `scrub` is
  read-only on the drive.
- A placed folder never moves automatically. No rebalancing (Backblaze backs
  up from the drives, so a moved folder is uploaded again). A folder changes
  drive or shape only through `reassign` (`--copy` copies drive-to-drive) or
  `split`.
- Placement units: one per top-level folder of a share, plus one `root` unit
  (keyed by the share name) for its loose top-level files. There is no
  `split:` setting. A new unit goes to a drive already holding part of its
  share if it fits there. A share an earlier build placed whole (a `tree` row
  keyed by the share name) stays one unit until `easy_sync split` converts
  it in place. See docs/fine-placement.md.
- Drives are matched by the serial in `<drive>/.easy_sync/drive.json`, never by
  mount path. Unknown or retired volumes are never written to.
- A missing or empty share is skipped, never mirrored.
- A folder with no real file on the NAS (only hidden/excluded names) is never
  placed (`Runner#empty_source?`); shows up in the report as `empty`, not `placed`.
- Placement always leaves `reserve` bytes free on a drive (config `:reserve:`,
  default 2gb) for APFS metadata, the `.easy_sync/` state copies, and rsync's
  temp file mid-copy.
- **`--dry-run` writes nothing, anywhere.** No folder assignment, no
  `sync_runs`/`pending_deletions`/`source_inventory` row, no drive usage/health
  update, no dashboard write, no `.easy_sync/` copy to any drive. This was
  violated once (dry-run recorded folders as synced with 0-duration,
  full-size "transfers"), found only by reading the dashboard after a real
  dry run — the specs hadn't asserted "manifest unchanged" strongly enough.
  If you touch `Runner#run`, grep it for `unless @dry_run` and make sure every
  new write site has the guard.
- A `sync` decides every placement first (phase 1: measure, place, record the
  full `source_inventory` — placed/unplaced/empty for every folder seen on the
  NAS), *then* copies (phase 2). This is why an interrupted 3-day copy still
  leaves a complete, accurate "what's backed up vs not" picture — don't
  collapse the phases back into one loop.
- Tile colour on the dashboard means SMART health, never fullness. A JBOD
  drive at 97% used is working as intended.
- The dashboard's "not backed up" count/list (from `source_inventory`) is the
  number a real user actually cares about — it's what tells them whether to
  buy another drive. Don't let a future change make it silently disappear
  again the way it did before `source_inventory` existed (dashboard only knew
  about *placed* folders, so with small test drives it quietly showed "94
  movies" and said nothing about the other 2,286 that didn't fit).
- Anything that shells out is injectable and faked in specs.
- Sync is intentionally sequential: one rsync process, one folder, at a time
  (`Runner#run`'s `plan.each { sync_folder }`, and `Shell#run` blocks on
  `wait.value` before returning). Don't parallelize this as a speed
  optimization — the source is one NAS behind one network link, so concurrent
  rsyncs would contend for the same bandwidth and NAS disks rather than add
  throughput; rsync itself has no `--parallel` flag for exactly this reason.
- `restore` (the reverse of `sync`, `lib/easy_sync/jbod/restorer.rb`) never
  passes `--delete`, on purpose: it only adds/updates files on the NAS,
  mirroring how the old drobo-sync restore scripts worked. It resolves a
  folder's NAS destination from the *current* `:sources:` config by matching
  the share name, so a folder whose share was `remove-source`d is skipped
  with an error telling you to `add-source` it again rather than guessed at.

## Verify live when you touch the sync path

Two 250 GB USB drives (`jbod-test-1`, `jbod-test-2`, APFS encrypted; the
passphrase is in the gitignored `CLAUDE.local.md`) exist for this. Keep a scratch config via `--config` so the real
`~/.easy_sync/` is never touched, and a scratch source tree under the scratchpad.
Several bugs here were only visible on real hardware; the specs encode the
assumptions, they cannot check them.

## Repo / process notes

- Public repo, solo maintainer (`CarlosEspejo` is the
  only collaborator with write access — verified via the collaborators API,
  not assumed). `main` protection: force-push and deletion blocked, **not**
  locked, **no** required reviews (dropped deliberately: required-review only
  gates people who already have write access, i.e. just the owner; it does
  nothing against non-collaborators, who can't push regardless of branch
  protection). If you ever re-add required reviews, remember
  `enforce_admins: false` lets the owner bypass them — a solo-maintainer PR
  can't self-approve otherwise.
- **After any backgrounded or slow `git commit`/`git push`, verify it actually
  landed** (`git log --oneline -1`, `git log origin/<branch>..HEAD`) before
  assuming success. One happened silently: a `commit && push` chain timed out
  and got auto-backgrounded, the tool call *looked* like it completed, but
  `git log` afterward showed the old HEAD — had to redo it in the foreground.
  A "failed" background-task notification for a command you've since
  superseded isn't necessarily a live problem, but check, don't assume either way.
- 2.0.0 dropped ALL 1.x compatibility on purpose (single-user gem, no reason
  to carry it): no snapshot mode, no nested `:jbod:` config layout, no
  `~/.easy_syncrc.yml` migration, no `easy_sync jbod <cmd>` alias, no legacy
  drive-marker path, no schema-upgrade path from pre-2.0 manifests (schema
  starts at version 1 again). Don't re-add any of this without being asked.
- Config is now flat and the tool *writes* it (`Config#save`, `Config.dump`):
  `add-source`, `remove-source`, `plan --apply` all rewrite
  `~/.easy_sync/config.yml` directly, preserving comments/order. A first-time
  user never has to hand-edit YAML.

## Open items

- Fine placement (no `split:` setting; `easy_sync split`; `reassign --copy`;
  Purger overlap guard) is built and passed the real-hardware checklist on
  2026-09-23 (docs/fine-placement.md). Not yet used on the real fleet: next
  step there is `easy_sync split synology --dry-run`, then `split synology`.

- Versioning of changed files: see docs/changed-file-grace.md (designed, not built).
- Bit-rot detection (`easy_sync scrub`) is built and passed the real-hardware
  checklist on 2026-09-21 (results in docs/integrity-scan.md). No drive in
  the real fleet has been scrubbed yet. `--all` works through every mounted,
  non-retired drive stalest first, defaulting to `scrub_jobs` (4) drives at
  once (see the parallel-scrub bullet below), so the first full pass is
  ~35 TB at the ~782 MB/s 4-way aggregate, about 12.5 hours, not the
  ~200 MB/s single-drive rate. `easy_sync scrub --for 8h` fits an overnight
  window either way.
- Parallel scrub (`scrub --jobs N`, one thread per drive, default 4) is built
  and verified against the real ThunderBay 8 fleet on 2026-09-21: see
  docs/parallel-scrub.md. 4 drives at once measured at ~782 MB/s aggregate,
  8 at once at ~1175 MB/s (both confirmed with `iostat`); the default stays
  4 since 8-way was only measured this one pass.
- Measured sync throughput (62.9 MB/s aggregate; any change to `sync` must
  keep the aggregate at 50 MB/s or more), per-drive benchmarks, enclosure
  bandwidth and hash speeds: docs/performance.md.
- Backblaze (Personal, taken from the drives): **1 year version history**,
  verified — the old Drobo volume is gone from today's backup but still
  browsable back to Sept 2025. A drive not connected for 30 days drops out of
  the *current* backup but stays in history, so it is a ~1-year countdown, not
  instant loss. `drives.last_seen_at` already has what a warning would need.
- **The OWC ThunderBay 8 (Thunderbolt) has replaced the Drobo.** 8 active
  drives, 44.59 TB; the two `jbod-test` drives are retired in the manifest,
  not deleted. The first full sync of the real library (~31.9 TB) finished
  around 2026-09-21 — check `easy_sync status` / the dashboard for current
  placement. `synology` (~2 TB) is still placed whole, so its sync ETA sits
  frozen for hours (SyncEta only learns when a folder finishes). Run
  `easy_sync split synology` (share and drive mounted) to place it folder
  by folder; nothing is copied. The NAS side limits sync speed, never the drives; Time
  Machine (backing up to the same Synology) is the first thing to check when
  a sync looks slow. Numbers and method: docs/performance.md.
- `easy_sync benchmark` is built (`Jbod::Benchmarker`, `drive_benchmarks`, last
  25 runs per drive). It was checked on `jbod-test-1` on 2026-09-22: 1.5 GB test
  file, write 86-99 MB/s, read ~163 MB/s (close to scrub's ~150 MB/s on it, so
  the page cache was bypassed), and Ctrl-C removed the test file. It has not
  been run on the real fleet yet. The first `benchmark --all` gives each drive
  its first entry; a SLOWER flag needs 3 earlier runs. It reports MiB/s (as
  scrub does); the 8 GB table in docs/performance.md doesn't say whether it
  used MB or MiB (~5% apart), so compare against it loosely.
- `gem install easy_sync` still fetches the old 0.0.5 from rubygems.org until
  someone runs `bundle exec rake release` (builds, tags `v2.0.0`, pushes the
  tag, publishes). Not done yet as of this writing.
