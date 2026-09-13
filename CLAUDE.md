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
- `du` over SMB: seconds for thousands of single-file movie folders, minutes for a
  share with hundreds of thousands of files. rsync's read-only walk of an
  unchanged folder is ~0.15 s.
- Headless Chrome refuses windows narrower than ~500 px; render phone widths
  inside a 400 px iframe.

## Invariants (never break these)

- rsync never deletes. Only `Purger` deletes, only after `grace_days` AND
  `grace_runs`, only inside the folder's own destination on a mounted drive.
- A placed folder never moves automatically. No rebalancing.
- Drives are matched by the serial in `<drive>/.easy_sync/drive.json`, never by
  mount path. Unknown or retired volumes are never written to.
- A missing or empty share is skipped, never mirrored.
- Tile colour on the dashboard means SMART health, never fullness.
- Anything that shells out is injectable and faked in specs.

## Verify live when you touch the sync path

Two 250 GB USB drives (`jbod-test-1`, `jbod-test-2`, APFS encrypted, passphrase
`jbodtest1234`) exist for this. Keep a scratch config via `--config` so the real
`~/.easy_sync/` is never touched, and a scratch source tree under the scratchpad.
Several bugs here were only visible on real hardware; the specs encode the
assumptions, they cannot check them.

## Open items

- Versioning of changed files: see docs/changed-file-grace.md (designed, not built).
- The real fleet (seven `backup-0N-…` drives) had not arrived when 2.0.0 was cut;
  first real run is `register-drive` x7, `plan`, `sync --dry-run`, `sync`.
- `gem install easy_sync` still fetches 0.0.5 until `bundle exec rake release`.
