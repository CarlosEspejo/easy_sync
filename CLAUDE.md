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

- Forwarding a signal to a child process (Ctrl-C during a copy) must signal its
  whole process group, not just its pid: `Open3.popen2e(*argv, pgroup: true)`,
  then `Process.kill('INT', -wait.pid)` (negative pid = the group). Signalling
  only the child's own pid left rsync's helper processes running and Ruby
  blocked waiting on them; a plain `sh -c '...; sleep N'` child in specs won't
  even forward the signal to its own `sleep` without this.

## Invariants (never break these)

- rsync never deletes. Only `Purger` deletes, only after `grace_days` AND
  `grace_runs`, only inside the folder's own destination on a mounted drive.
- A placed folder never moves automatically. No rebalancing.
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

Two 250 GB USB drives (`jbod-test-1`, `jbod-test-2`, APFS encrypted, passphrase
`jbodtest1234`) exist for this. Keep a scratch config via `--config` so the real
`~/.easy_sync/` is never touched, and a scratch source tree under the scratchpad.
Several bugs here were only visible on real hardware; the specs encode the
assumptions, they cannot check them.

## Repo / process notes

- PR #1 (43 commits, the whole JBOD rewrite) is merged into `main` (renamed
  from `master` — GitHub's rename endpoint, not delete+recreate, so old
  clones/links redirect). Public repo, solo maintainer (`CarlosEspejo` is the
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
  user never has to hand-edit YAML. `plan [SHARE...] [--apply]` can be scoped
  to one or more shares by folder name or full path, to avoid re-measuring a
  10+-minute share just to check one small one.

## Open items

- Versioning of changed files: see docs/changed-file-grace.md (designed, not built).
- Bit-rot detection: see docs/integrity-scan.md (designed, not built). Read the
  doc before touching this; the decisions below were argued out and should not
  be re-litigated.
  - **Why it matters here specifically: the offsite backup is taken from the
    drives, not from the NAS.** A rotted file gets uploaded as a change and
    corrupts the last copy standing. That is the whole justification.
  - **`sync` does no hashing. `verify` writes every baseline.** Throughput is
    **62.9 MB/s aggregate** — measured from `sync_runs`, 154 folder copies of
    5 GB+, 11.3 TB over 49.9 h; median folder 67.7, p10–p90 50.2–87.6. Plan
    with the aggregate, not the spread: it is what predicts wall-clock time.
    The acceptance criterion is that integrity work never drops the
    *aggregate* below 50 MB/s — as an instantaneous floor it is already
    breached, 10.7% of transfer time runs under 50 today. A post-copy hash
    pass costs 25–33%, i.e. 42–47 MB/s, so it breaks the floor outright,
    which is why it was moved out. Don't re-derive any of this by eye from an
    rsync log: the rate `--info=progress2` prints is a *cumulative average*
    (bytes ÷ elapsed), so it sags smoothly and understates the real spread.
  - Measured, don't re-derive: rsync prints a per-file checksum for free via
    `--out-format='%i %C %l %n'` (no `--checksum` needed), stable across runs.
    **We deliberately do not use it** — it forces `--checksum-choice=md5`,
    covers only transferred files, and MD5/xxh128 are not sound choices. Use
    SHA-256 (2514 MB/s on Apple Silicon vs MD5's 763); the disk is always the
    bottleneck, never the hash.
  - A file found corrupt is **guaranteed to be replaced**: `verify` flags the
    row, the next `sync` of that folder deletes the flagged file before its
    copy pass so rsync re-fetches it. This amends the "only Purger deletes"
    invariant above — update it when this is built.
  - SnapRAID was evaluated and rejected: it won't give you scrub without
    parity, parity costs a 7.28 TB drive against only ~5.4 TB of headroom, and
    it identifies drives by config path rather than by serial.
- Backblaze (Personal, taken from the drives): **1 year version history**,
  verified — the old Drobo volume is gone from today's backup but still
  browsable back to Sept 2025. A drive not connected for 30 days drops out of
  the *current* backup but stays in history, so it is a ~1-year countdown, not
  instant loss. `drives.last_seen_at` already has what a warning would need.
- **The OWC enclosure has replaced the Drobo and is what's in use now.** The
  real fleet is 8 active drives, 44.59 TB total: 4 × 7.28 TB, 2 × 5.46 TB,
  1 × 2.73 TB, 1 × 1.82 TB (the two 235 GB `jbod-test` drives are retired in
  the manifest, not deleted). A first real `sync` (not a test-drive run) is in
  progress against the real library (`tv` 17.7 TB/~308 folders, `movies`
  12.3 TB/~2,379 folders, `synology` 1.9 TB/16 folders + loose top-level files
  so it must stay `split: false`, `pro` 35.6 GB/4 folders) — about 31.9 TB
  against 44.59 TB of capacity. Check `easy_sync status` / the dashboard for
  current placement; don't assume the old test-drive partial-fit numbers apply.
  Sync speed needs no further measuring — it is network IO plus the single
  target drive being written, measured at 62.9 MB/s aggregate (see
  docs/integrity-scan.md for the method and the per-drive breakdown, which
  confirms the target drive is not the variable: five drives within 2.4 MB/s
  of each other). Time Machine on this Mac backs up to a sparsebundle on the
  *same* Synology that serves the media shares, so it contends with rsync's
  reads on the same array and link — `sudo tmutil disable` during a long
  campaign is worth it, and it is the first thing to check when a sync looks
  slow. The one speed question
  still genuinely open is whether the enclosure sustains N concurrent
  *reads* over its single USB-C link, which only matters for parallelising a
  future `verify`.
- `gem install easy_sync` still fetches the old 0.0.5 from rubygems.org until
  someone runs `bundle exec rake release` (builds, tags `v2.0.0`, pushes the
  tag, publishes). Not done yet as of this writing.
