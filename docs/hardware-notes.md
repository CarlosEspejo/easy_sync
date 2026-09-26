# Things learned on real hardware

Do not re-derive these: each was found on real drives, rsync or macOS tools,
and the specs only encode the assumption, they cannot check it. Read the
relevant entry before changing code that touches that tool.

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
- A smartctl read can fail once on a drive that reads fine minutes before
  and after (backup-07-6tb in the ThunderBay, 2026-09-23). `smart_health`
  retries, and `Runner#check_health` keeps the last known status rather
  than overwriting it with 'unknown'.
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
- `diskutil eject disk4` (the whole physical disk, from `physical_disk_for`
  minus its partition suffix) on an encrypted APFS USB drive prints
  `Disk disk4 ejected`, exits 0, and the volume leaves `/Volumes` and the
  disk leaves `diskutil list` (jbod-test-1/2, 2026-09-26). Getting it back
  takes a replug. With a file held open on the volume, the eject fails and
  macOS names the holder ("dissented by PID 38139 (/bin/sleep)"): `easy_sync
  eject` reported "in use by pid 38139 (/bin/sleep)", exited 1, and the
  drive stayed mounted (jbod-test-1, 2026-09-26).
- Backblaze Personal's state (read by `Jbod::Backblaze`, never written) is
  world-readable under `/Library/Backblaze.bzpkg/bzdata`: `bzvolumes.xml`
  maps a volume GUID to its mount point as hex with a trailing slash;
  `bzreports/bzstat_remainingbackup.xml` has files/bytes left per GUID;
  `bzfilelists/<GUID>______filelist.dat`'s mtime is that volume's last
  scan (2026-09-26: 09:47-10:01 local for the fleet, all 0 left). A zero
  counted before easy_sync's last copy onto the drive is stale, hence
  the `waiting` state. spec_helper stubs `Backblaze::DATA_DIR` into the
  temp dir: no spec may read the real install.
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
