# easy_sync: notes for whoever works on this next

macOS-only Ruby gem (2.0.0) that mirrors NAS shares onto independent drives.
README.md is the user-facing truth; this file is for working on the code.
Feature designs, real-hardware results and measurements live in `docs/`
(map at the bottom).

## Run the suite before every push

    bundle exec rake            # a few seconds, 500+ examples, no drives or rsync needed

- Every external call (rsync, df, du, diskutil, smartctl, caffeinate) goes through
  `EasySync::Shell`; specs inject `FakeShell` (spec/support/fake_shell.rb) and
  register responses with `fake_shell.on(...)`. Never let a spec shell out for real.
- spec_helper redirects the home directory (`Config::HOME_DIR`) and the
  Backblaze install (`Backblaze::DATA_DIR`) into the temp dir. Keep it that
  way: an earlier test found the developer's real config and moved it into a
  temp dir that was then deleted. Any new default path must be derived at call
  time (`Config.defaults`), never at load time.
- Specs use paths under `temp_dir`, never literal `/Volumes/...` (that broke on a
  real Mac where `/Volumes` is not writable).

## Before touching rsync flags, diskutil/smartctl parsing, `Shell`, the schema, scrub's reads or Backblaze

Read docs/hardware-notes.md. Each entry there was learned on real drives or
tools and would be expensive to re-derive (rsync 3.5's `--exclude=/*/` and
`--max-delete` behaviour, smartctl exit codes, the manifest's stale
`user_version` 5, `F_NOCACHE` vs. the page cache, signalling a process
group, `diskutil eject` output, Backblaze's state files).

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
  drive only through `reassign` (`--copy` copies drive-to-drive).
- Placement units: one per top-level folder of a share, plus one `root` unit
  (keyed by the share name) for its loose top-level files. A new unit goes to
  a drive already holding part of its share if it fits there. Nothing splits
  a single top-level folder further: one bigger than every drive stays
  unplaced ("not backed up"). See docs/fine-placement.md.
- Drives are matched by the serial in `<drive>/.easy_sync/drive.json`, never by
  mount path. Unknown or retired volumes are never written to.
- A missing or empty share is skipped, never mirrored.
- A folder with no real file on the NAS (only hidden/excluded names) is never
  placed (`Runner#empty_source?`); it shows in the report as `empty`.
- Placement always leaves `reserve` bytes free on a drive (config `:reserve:`,
  default 2gb) for APFS metadata, the `.easy_sync/` state copies, and rsync's
  temp file mid-copy.
- **`--dry-run` writes nothing, anywhere**: no folder assignment, no
  `sync_runs`/`pending_deletions`/`source_inventory` row, no drive usage or
  health update, no dashboard, no `.easy_sync/` copy to any drive. It was
  violated once and found only by reading the dashboard after a real dry run.
  If you touch `Runner#run`, grep it for `unless @dry_run` and guard every new
  write site; specs must assert the manifest is unchanged.
- A `sync` decides every placement first (phase 1: measure, place, record the
  full `source_inventory` for every folder seen on the NAS), *then* copies
  (phase 2). That is why an interrupted 3-day copy still leaves an accurate
  "what's backed up vs not" picture. Don't collapse the phases into one loop.
- Tile colour on the dashboard means SMART health, never fullness. A JBOD
  drive at 97% used is working as intended.
- The dashboard's "not backed up" count (from `source_inventory`) is the
  number the user acts on: it says whether to buy another drive. It once
  silently disappeared (the dashboard only knew *placed* folders); don't let a
  change hide it again.
- Anything that shells out is injectable and faked in specs.
- Sync is sequential on purpose: one rsync, one folder at a time. The source is
  one NAS behind one link, so parallel rsyncs would contend, not add
  throughput. `sync` must keep its aggregate at 50 MB/s or more
  (docs/performance.md).
- `restore` never passes `--delete`: it only adds/updates files on the NAS. It
  resolves a folder's NAS destination from the *current* `:sources:` by share
  name, so a folder whose share was `remove-source`d is skipped with an error,
  never guessed at.
- Backblaze is optional: everything about it (`status`/dashboard upload state,
  the 30-day disconnect countdown, `eject`'s prompt) appears only when
  `Jbod::Backblaze.read` finds an install.

## Verify live when you touch the sync path (or anything in hardware-notes)

Two 250 GB USB drives (`jbod-test-1`, `jbod-test-2`, APFS encrypted; the
passphrase is in the gitignored `CLAUDE.local.md`) exist for this. Use a
scratch config via `--config` so the real `~/.easy_sync/` is never touched,
and a scratch source tree under the scratchpad. Several bugs here were only
visible on real hardware. Record what you learn in docs/hardware-notes.md.

## Repo / process notes

- Public repo, solo maintainer. `main` blocks force-push and deletion; no
  required reviews (they would only gate the owner). Work on a branch and open
  a PR; the owner squash-merges.
- The repo is public: never commit real drive serials, volume UUIDs, folder
  names from the library, or passphrases, not even in a comment, a spec or a
  doc. Use made-up ones (`SN-backup-04-8tb`, `movies/Metropolis (1927)`).
  Drive names (`backup-0N-Xtb`), share names, models and fleet-wide counts
  are fine. Older commits still hold five serials and the test drives'
  passphrase; history was deliberately not rewritten.
- The README's dashboard screenshots come from
  `bundle exec ruby script/dashboard_screenshot.rb` (a made-up manifest and
  Backblaze install). Re-run it and commit the PNGs when the dashboard's look
  changes.
- A slow `commit && push` can be auto-backgrounded and look finished when it
  isn't: `git log origin/<branch>..HEAD` must be empty before calling it done.
- 2.0.0 dropped all 1.x compatibility on purpose (snapshot mode, nested
  config, `~/.easy_syncrc.yml` migration, `easy_sync jbod` alias, old markers,
  pre-2.0 schema upgrades). Don't re-add any of it unless asked.
- The tool writes its own config (`Config#save`): `add-source` and
  `remove-source` rewrite `~/.easy_sync/config.yml`, preserving comments and
  order. A user never has to hand-edit YAML.
- Release: `bundle exec rake release` builds, tags `v2.0.0`, pushes the tag
  and publishes. Until it has run, `gem install easy_sync` gets 0.0.5
  (`git tag -l v2.0.0` tells you which). Date the CHANGELOG entry first.

## Where things are documented

- docs/hardware-notes.md: traps found on real drives, rsync and macOS tools.
- docs/fine-placement.md: folder-by-folder placement, `reassign --copy`, the
  Purger overlap guard, and its real-hardware results.
- docs/tripwire.md: the ransomware tripwire, report-only until
  `tripwire_enforce`, and what it needs measured before enforcing.
- docs/integrity-scan.md: `scrub` (bit-rot detection), its real-hardware
  results, the fleet's first full pass, and the Backblaze disconnect warning.
- docs/parallel-scrub.md: `scrub --jobs N`.
- docs/performance.md: sync throughput, drive, enclosure and hash speeds,
  `benchmark` results. The NAS limits sync speed, never the drives; Time
  Machine on the same Synology is the first suspect when a sync is slow.
- CHANGELOG.md: major features per release.
