# Fine placement: no `split` setting (built and verified on real hardware)

Every share is placed one top-level folder at a time, plus one unit for its
loose top-level files. The `split:` setting is gone, and `reassign ... --copy`
moves folders between drives by hand. If anything here disagrees with the
code, the code wins; fix this doc.

Shares that an earlier build placed whole were converted in place by an
`easy_sync split SHARE` command. It converted the last two on the real fleet
(`synology` and `pro`, 2026-09-23) and was removed on 2026-09-25, together
with `Runner`'s support for whole-share rows. The two `split` events it wrote
are still in `placement_history`.

## Problem

Each source used to carry `split: true|false`:

- `false`: the whole share is one unit (`folders.folder_path` = `"synology"`).
- `true`: each top-level subfolder is a unit (`"synology/Movies"`), and loose
  top-level files are silently not backed up.

That caused three problems:

1. **Changing the setting could delete live data.** After a flip the old key
   disappears from the listing. `Runner#reconcile_manifest` recorded it as a
   whole-folder `missing_on_nas` deletion, and after `grace_days`/`grace_runs`
   `Purger` ran `rm_rf <drive>/synology`. The new per-folder units sync to
   `<drive>/synology/<sub>`, *inside* that path, so they would be deleted too.
   Merging back had the same problem in reverse.
2. **Users had to choose, and some couldn't.** `synology` had to stay whole
   only because of loose root files, even though it is ~2 TB.
3. **A huge unit freezes the sync ETA.** `SyncEta` only learns when a folder
   finishes, so a 2 TB unit shows the same "remaining" figure for hours.

## Decisions (settled, don't re-open)

- **No automatic moves, ever.** mergerfs and unRAID don't rebalance
  automatically either: they place small units when data arrives, and
  moving data is a manual tool (`mergerfs.balance`, unBALANCE). Here moving
  is even more expensive: Backblaze backs up *from the drives*, so a moved
  folder is uploaded again, and the drives are often offline. Placed folders
  change drive only through `reassign`.
- **Always one unit per top-level folder, plus a root-files unit.** No
  setting. A share can be any size, and every drive stays readable in Finder.
- **Keep a share together while it fits.** `Placement.choose(prefer:)` picks,
  among drives already holding part of the share, the one with the most free
  space that the unit fits on. Otherwise it picks the most free space
  overall. This keeps the "one collection per drive" browsing the old whole
  setting gave, and splits a share only when it has to.
- **The Purger guard stays even though a normal sync can no longer reach the
  bug.** A hand-edited manifest, or a future bug, must not be able to
  reproduce it.

## Schema

`folders.scope TEXT NOT NULL DEFAULT 'tree'`, added by checking
`PRAGMA table_info` (CLAUDE.md: the real manifest is stamped version 5).

- `tree`: the folder and everything under it.
- `root`: a share's loose top-level files only. `folder_path` is the share
  name; the share's subfolders are separate `tree` folders.

## Components

**`Runner#units_of`** (`runner.rb`). Emit one unit per top-level subfolder, plus
`SourceFolder(root_only: true)` when the share has loose files or already
has a root row. A root row is emitted even once its files are gone, so their
removal is noticed. `Jbod::ShareScan` is the one rule for what counts as a
subfolder or a loose file (hidden and `exclude_folders` names never count).
A root unit is sized by summing its loose files, never by `du` of the share.

**`Mirror` `root_only`.** The copy pass adds `--exclude=/*/` (anchored,
directories only). The probe uses `--delete --exclude=/*/` **without**
`--delete-excluded`, so rsync protects the excluded subfolders and never
reports them. Checked against rsync 3.5.0 on scratch directories: the copy
moved only the two top-level files, and the probe reported only a stale
top-level file, not `TV/` (present on the destination only) or `Movies/`.

**`Purger`.**
- Before any whole-folder `rm_rf`, it skips the candidate if a live folder on
  the same drive sits below its path, or if its path sits below a live
  `tree` folder. The warning says `<live> is a live folder that overlaps it`.
  The candidate is kept and checked again every run.
- A whole-folder candidate for a `root` folder deletes only the top-level
  files, never `rm_rf`.

**`Scrubber` / `Cleaner` / `Restorer`.** For a `root` folder, each touches
only the top level: scrub hashes only top-level files, clean removes only
top-level junk, restore adds `--exclude=/*/`. `restore SHARE` includes the
root unit along with every folder under the share.

**`reassign FOLDER|SHARE DRIVE [--copy]`.** A share name moves every folder
of the share (root unit included) except those already on the target. The
capacity check covers the total. `--copy` (under `RunLock`, both drives
mounted) runs one local `rsync -a --partial` per folder, the same way
`copy_drive` does, adding `--exclude=/*/` for a root unit. It then calls
`reassign_folder`, so the old copy's cleanup still waits for an `ok` sync on
the new drive (`Purger#ready?`). A failed copy leaves that folder recorded
where it was.

**Removed:** `split:` in the config (a leftover key is ignored and dropped on
save), `add-source --split/--whole` and its guessing logic, `plan --apply`
and the split advice. `plan` now only reports sizes and whether every folder
fits. The dashboard's "loose files not backed up" alert is gone, since they
are backed up now.

## Tests

`purger_spec` (overlap guard both ways, `-archive` names, other drives, root
units), `mirror_spec` (root-only argv), `placement_spec` (`prefer:`),
`runner_spec` (units, root unit, affinity within a run and across runs, a
folder gone from the NAS flagged alone), `scrubber/cleaner/restorer_spec`
(root units), `cli_spec` (`reassign --copy`, share form, failure, drive not
mounted).

## Verify on real hardware before merging

Kept as the record of what was checked; steps 1-2 used `split`, which is
gone now.

On `jbod-test-1`/`jbod-test-2` with a scratch `--config` (CLAUDE.md, "Verify
live"), and a scratch share with `Movies/`, `TV/` and two loose root files:

1. Make the share a whole placement on `jbod-test-1` (a `tree` row keyed by
   the share), sync it.
2. `split SHARE`: no rsync runs; rows for `SHARE/Movies`, `SHARE/TV`, and
   `SHARE` becomes `root`; inodes unchanged.
3. `sync`: ~0 bytes transferred; the root unit copies only loose files.
   Delete a loose file on the NAS → only that file becomes pending. Delete
   `TV/` on the NAS → only `SHARE/TV` becomes pending.
4. A new share syncs as per-folder units, all on one drive while it fits.
5. `reassign SHARE jbod-test-2 --copy`: local rsync only; the next sync
   transfers ~0 bytes; the old copy is only removed after an `ok` sync and
   the grace period.
6. Hand-craft the original bug (a whole-folder pending over a live
   subfolder), expire it: Purger skips it with a warning, and nothing is
   deleted.

## Results (2026-09-23, jbod-test-1/2, scratch config, all six steps passed)

The scratch "NAS" was a local tree (`fpshare`: `Movies/` 64 MB, `TV/` 32 MB,
two loose files; `fpshare/` placed whole on `jbod-test-1` through a `tree`
row). The drives' own `.easy_sync/` folders were backed up first and
restored afterwards, identical.

1. The whole share synced as one unit, 100.7 MB; `sources` said
   "placed whole; `easy_sync split fpshare` places its folders one by one".
2. `split fpshare --dry-run` wrote nothing. `split fpshare` gave
   `fpshare` (root, 20 B), `fpshare/Movies`, `fpshare/TV`, all on
   jbod-test-1, with 0 pending deletions. Every file kept its inode.
3. The next `sync` transferred **0 bytes** for all three units. The root
   unit's rsync total was 20 B (only the loose files), so `--exclude=/*/`
   behaves on the real drive as it did on scratch dirs. After deleting
   `loose2.txt` and `TV/` on the NAS, exactly two candidates appeared:
   (`fpshare/TV`, whole folder) and (`fpshare`, `loose2.txt`); the root
   unit's probe did not report `TV/`. Once expired, the purge removed just
   those two; `Movies/` and `loose1.txt` were untouched.
4. `add-source fpnew` dropped the leftover `:split: false` from the config
   on save; `plan` only reported. The sync placed `fpnew/A` on the drive
   with the most free space and `fpnew/B` "with the rest of fpnew".
5. `reassign fpshare jbod-test-2 --copy` ran two local rsyncs (the root
   unit's copied only `loose1.txt`). The next sync transferred 0 bytes. The
   old copies were removed from jbod-test-1 only after that `ok` sync and
   the (backdated) grace period. That run left an empty `fpshare/`
   directory behind, so `Purger` now removes a share directory once its
   last folder is gone from the drive (specced).
6. A stale, expired whole-folder candidate for `fpnew` over the live
   `fpnew/A` and `fpnew/B`: sync warned "not purging fpnew (whole folder):
   fpnew/A is a live folder that overlaps it on jbod-test-2; not deleting
   (resolve by hand)", and both files survived. A first attempt with a
   `tree` row for `fpnew` never reached Purger at all: the share is on the
   NAS, so the sync cleared the candidate as reappeared. The original bug
   path cannot occur through a normal sync any more; the guard is the
   backstop.
