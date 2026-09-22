# Parallel scrub: `easy_sync scrub --jobs N` (built and verified on real hardware)

The build spec for scrubbing several drives at once. Every decision below was
already argued out; implement it as written, and if the code forces a change,
update this doc in the same PR. Read `docs/integrity-scan.md` first: this only
changes *how many* drives `scrub` works on at a time, never what it does to
one drive.

## Why

A full scrub of the fleet (~35 TB) takes about 2 days, because `scrub --all`
does one drive at a time and a drive reads at 170-200 MB/s. The drives are
not sharing a bottleneck. Measured on 2026-09-21 with Scrubber's own read
path (8 MB `File#read` chunks, `F_NOCACHE`), cold files, all in the ThunderBay 8:

| drives at once | per-drive MB/s | aggregate MB/s |
|---|---|---|
| 1 | 169-191 | ~180 |
| 2 | 169, 202 | ~350 |
| 4 (7-9 GB files each) | 184, 180, 173, 172 | **641** (90% of the sum of solo speeds) |

Each bay has its own AHCI controller on a 40 Gb/s Thunderbolt link
(docs/performance.md, "Enclosure bandwidth"), so 8-way should scale too, but
only 4-way is measured. SHA-256 runs at ~2,800 MB/s on one core, so CPU is
never the limit.

This is the opposite of `sync`, which is sequential on purpose (one NAS, one
network link; CLAUDE.md invariants). Do not use this doc as a reason to
parallelize `sync`.

## Decisions (do not re-litigate)

1. **Threads, not processes.** The work is I/O-bound; MRI releases the GVL
   during blocking `File#read`, so threads overlap the reads. Processes would
   mean result marshaling and redoing the process-group signal forwarding
   CLAUDE.md warns about. No new gems.
2. **SQLite: WAL + one connection per worker.** Not a write queue. Details
   in "Manifest" below.
3. **One drive per worker.** Never two workers on the same drive (two
   readers on one spindle just seek against each other). Rows are
   partitioned by `drive_serial`, so workers never touch each other's rows.
4. **Default 4 jobs**, the largest count actually measured. `--jobs 1` must
   behave exactly like today's sequential `scrub --all`.

## Behavior

    easy_sync scrub [NAME ...] [--all] [--jobs N] [--for DURATION] [--dry-run] [--no-keep-awake]

- `--jobs N` (N >= 1; reject 0/negative/non-integer with an `Error`).
  Default comes from config `scrub_jobs` (default 4), added to
  `Config::DEFAULTS`, `KEY_COMMENTS` and `SAMPLE` the same way
  `scrub_stale_days` was.
- Plain `scrub` (no names, no `--all`) still picks one drive, so jobs is
  irrelevant there. Named targets and `--all` go through the pool.
- Work order is unchanged: targets are resolved exactly as
  `CLI#resolve_scrub_targets` does today (stalest first for `--all`, given
  order for names) and put on a `Queue`. `min(jobs, targets.size)` worker
  threads each pop the next target, scrub it, and pop again until the queue
  is empty. With 8 drives and 4 jobs, the 4 stalest start first and the rest
  start as slots free up.
- `--for`: the deadline is shared. A worker that finds `clock.now >=
  deadline` before popping stops without starting a new drive (a new drive
  would otherwise run its whole walk phase before the hash loop notices the
  deadline). A drive already mid-hash stops at its next file, as today.
- A drive that gets unmounted stops only its own worker's drive; that worker
  moves on to the next target.
- `--dry-run` goes through the same pool (it only reads), so output lines
  must be attributable to a drive (see "Output").
- Exit code, the "Scrub finished" / "Scrub stopped early (...)" final line,
  and `findings`/`stopped` aggregation are unchanged; build them from the
  collected `Result`s in **target order**, not completion order, so the log
  summary is deterministic.

## Code changes

### `Jbod::ScrubPool` (new, `lib/easy_sync/jbod/scrub_pool.rb`)

Owns the threads so `CLI#scrub` stays readable and the threading is testable
without the CLI. Suggested shape:

    ScrubPool.new(jobs:, open_manifest:, scrubber_options:, lock:, clock:, deadline:, out:)
    #run(targets) -> [Result, ...] in target order

- `open_manifest` is a lambda returning a new `Manifest` (the CLI passes
  `-> { Jbod::Manifest.open(settings[:manifest_path]) }`).
- **Open all worker manifests on the calling thread before starting any
  thread.** `Manifest#initialize` runs `migrate!` and the WAL pragma; doing
  that from N threads at once invites lock errors on the first run.
- Each worker: own `Manifest`, own `Scrubber.new(manifest, **scrubber_options)`.
  `Scrubber` itself does not know it is in a pool.
- Close every worker manifest in an `ensure` after joining.
- Track the set of drives currently being scrubbed (a `Set` under a `Mutex`);
  after every add/remove call `lock.note(*active_names)` (see RunLock).
- **Ctrl-C.** `Interrupt` arrives on the main thread, which is blocked in
  `join`. Rescue it there, `t.raise(Interrupt)` every live worker (this
  interrupts a blocked `File#read`, matching today's "stop mid-file, leave
  that row untouched" behavior), join them all (swallowing their
  `Interrupt`), then re-raise so `CLI#scrub`'s existing `rescue Interrupt`
  logs the interrupted line. Waiting for workers to reach a file boundary is
  wrong: one file can be 58 GB (several minutes).
- Any other exception in a worker: let it propagate out of `join`/`value`
  after stopping the other workers the same way (so they flush). Don't
  swallow it.

### `Scrubber#hash_phase`: buffer outcomes, flush in short transactions

Today `hash_phase` opens a transaction, keeps it open, and commits and
reopens every `COMMIT_INTERVAL` (30 s). In WAL, a connection holds the single
write lock from its first write until commit, so one worker would hold the
lock ~30 s at a time and every other worker's write would time out. So:

- Collect outcomes in an array (`[args, kwargs]` for each `checksum_hashed`
  call that `record_hash`/`record_read_error`/the vanished branch make today)
  instead of writing immediately.
- Flush every `COMMIT_INTERVAL` and in `ensure`: one
  `db.transaction(:immediate) { pending.each { ... checksum_hashed ... } }`,
  then clear the array. Lock held for milliseconds.
- Wrap the `ensure` flush in `Thread.handle_interrupt(Interrupt => :never)`
  so a `Thread#raise` from the pool can't abort it half-way. Outcomes already
  in the buffer are for files that were fully read and are valid to record.
- Keep "one `@clock.now` read per file" (the deadline spec counts calls);
  flushing must not read the clock.
- Print the progress line right after each interval flush, as now.

This is the only `Scrubber` change besides output prefixes. It applies to
`--jobs 1` too; the single-drive path must keep passing every existing spec
unchanged.

### `Manifest`

- In `Manifest.open` (not `new`, so `:memory:` specs are untouched), before
  `migrate!`: `db.execute('PRAGMA journal_mode = WAL')` unless path is
  `':memory:'`, and on every connection `db.busy_timeout = 30_000`
  (sqlite3 2.9.6 has `Database#busy_timeout=`). WAL is sticky in the file,
  so the real manifest switches the first time any command opens it.
  Consequence: `manifest.sqlite3-wal` and `-shm` appear next to it; nothing
  copies the manifest file directly (`backup_to` uses the online backup API,
  which is WAL-safe), so that is cosmetic.
- Change every `db.transaction do` in `Manifest` to
  `db.transaction(:immediate) do`. A deferred transaction that reads and then
  writes can fail in WAL with `SQLITE_BUSY` *without* the busy handler
  retrying (another connection committed after its read snapshot). Immediate
  takes the write lock at `BEGIN`, where `busy_timeout` does apply. Scrub uses
  `reconcile_checksums` (walk phase) this way, but changing all of them is
  simpler than auditing which ones can race and costs nothing single-threaded.

### `RunLock#note`: plural

Today the lock file is `pid\nkind\n` plus one optional third line (the drive
`scrub` is on). Change `note(text)` to `note(*names)`, writing each name on
its own line from line 3 on (friendly names are not validated, but a newline
in one is not realistic). `Status#current` becomes an `Array` of names
(empty when none). Update callers:

- `CLI#print_scrub_status`: `run.current.include?(d.friendly_name)`.
- `Dashboard#scrubbing?`: same.
- `CLI#print_run_status`: for a scrub, append `on backup-01-8tb, backup-03-8tb`
  when `current` is non-empty.
- Existing `run_lock_spec` note/current specs move to the array form.

Keep: `note` preserves the lock file's mtime (the run's start time) and is a
no-op unless this process holds the lock.

### Output

- `RunLog#puts` and `#print` wrap their two writes in a `Mutex`, so lines
  from different threads never interleave mid-line.
- Every line a `Scrubber` prints must name its drive. Progress lines, the
  per-drive summary and `stopped:` lines already do. Prefix the two
  `WARNING:` lines (walk "could not walk it completely" and hash_one
  "skipped, left as it was") with `"#{result.drive}: "`, and the dry-run
  line already starts with the drive.
- Header line gains `· jobs N` when N > 1.

### CLI / docs

- `CLI#scrub`: parse `--jobs`, build the `ScrubPool`, keep the RunLock /
  RunLog / KeepAwake / final-line / exit-code code as is around it.
- `COMMAND_GROUPS` usage line and README: document `--jobs N`, the default,
  and that it is scrub-only. README config example gains `scrub_jobs: 4`.
- CLAUDE.md: replace the "first full pass ... about 2 days" wording in Open
  items with the measured parallel number once the hardware check below is
  done; add the 4-way scaling result under "Things learned on real hardware".
- docs/performance.md "Enclosure bandwidth": add the table from "Why" above.
- Flip this doc's title to "(built, not yet verified on real hardware)" when
  code lands, and to "(built and verified on real hardware)" with a Results
  section after the checklist passes, as integrity-scan.md did.

## Tests

`ScrubPool` and anything using more than one connection needs a
**file-backed** manifest (`Manifest.open(File.join(temp_dir, 'm.sqlite3'))`):
every `:memory:` connection is its own separate database. Real files, no
FakeShell, like `scrubber_spec`.

- Manifest: `Manifest.open` on a file reports `journal_mode` `wal` and a
  30 s busy timeout; `:memory:` still works.
- Scrubber: outcomes are written in batches (stub/spy the transaction: with
  a ticking clock crossing `COMMIT_INTERVAL` once, exactly two flushes; with a
  static clock, one flush at the end); a run interrupted by `Interrupt`
  raised from inside `File.open` for file N still records files 1..N-1 and
  leaves file N untouched. All existing scrubber specs pass unmodified.
- ScrubPool, 3 drives on disk (reuse `write_marker`-style setup):
  - `jobs: 2` baselines every file on all 3 drives and returns results in
    target order.
  - never more than `jobs` `Scrubber#run` calls in flight at once, and never
    two on the same drive (instrument `run` with a counter under a mutex).
  - past the deadline, no new drive is started.
  - `lock.note` receives the active set as drives start and finish
    (spy on `note`).
  - `Interrupt` on the calling thread stops all workers and re-raises; rows
    for completed files are present.
  - an exception in one worker propagates, and other workers' completed
    rows are still flushed.
- CLI: `--jobs 0`/`--jobs x` rejected; `--jobs 2 --all` scrubs everything;
  `status` shows "scrubbing now" for every name in a multi-line lock file;
  `print_run_status` lists the active drives.
- Dashboard: two tiles show "scrubbing now" when `current` has two names.
- RunLog: many threads calling `puts` concurrently produce only whole lines.

## Verify on real hardware before merging

Use a scratch `--config` whose `manifest_path`, `log_dir`, `lock_path` and
`dashboard_path` point into a scratch directory, so the real
`~/.easy_sync/` is never touched (CLAUDE.md, "Verify live"). Scrub only reads
the drives, so the real fleet can be the target. The scratch manifest needs
the fleet registered: copy the real manifest into the scratch dir first
(`sqlite3 ~/.easy_sync/manifest.sqlite3 ".backup <scratch>/manifest.sqlite3"`),
then use `--for` so each step is bounded.

1. `scrub --all --jobs 4 --for 5m`: aggregate throughput (sum of bytes read /
   wall time from the per-drive summary lines) within ~15% of 4x one drive.
   `iostat -w 5` shows 4 disks busy.
2. While step 1 runs: `status --config <scratch>` lists all 4 drives as
   "scrubbing now"; `dashboard --config <scratch>` shows 4 tiles likewise.
   A 5th drive starts as soon as one finishes (use a small drive, e.g.
   backup-08-2tb, among the first 4 to see it).
3. `--jobs 8 --for 5m`: record the 8-way aggregate in docs/performance.md
   whether or not it scales. If it doesn't, leave the default at 4.
4. Ctrl-C mid-run: every worker stops within a few seconds (not at the end of
   its current file), the log says "interrupted", and a follow-up
   `scrub --all --jobs 4 --for 2m` resumes with no row reset and no findings.
5. `sqlite3 <scratch>/manifest.sqlite3 "PRAGMA integrity_check;"` -> `ok`,
   and `PRAGMA journal_mode;` -> `wal`.
6. The WAL switch touches `sync`'s database too: run `sync` against the
   `jbod-test` drives with a scratch config (CLAUDE.md, "Verify live") and
   confirm it completes and `status`/dashboard read back normally.
7. No output line in the scrub log is interleaved or lacks a drive name.

## Results (2026-09-21, against the real ThunderBay 8 fleet)

All 7 checks above passed on a scratch config against the real fleet (all 8
drives, none of the two `jbod-test` drives, which are retired):

1. `--jobs 4 --for 5m`: 4 drives (backup-01/02/03/04) read concurrently,
   ~782 MB/s aggregate (docs/performance.md), `iostat -w 2` showed exactly 4
   physical disks busy the whole time.
2. `status --config <scratch>` (run from a second process, reading the same
   lock file) listed all 4 as "scrubbing now" in one line; the dashboard
   showed 4 tiles the same way.
3. `--jobs 8 --for 3m`: all 8 active drives ran at once (`iostat` confirmed
   8 disks busy), ~1175 MB/s aggregate - default stays 4 (the largest
   *measured before this pass*; 8 works too, but nothing changes the
   default without more runs to be sure it's not the two 2 TB/3 TB drives
   inflating the average).
4. `kill -INT` on the process 8s in: exited in well under a second, log said
   "Scrub interrupted (Ctrl-C)", the lock file was removed, and a follow-up
   `--jobs 4` resumed on the same 4 drives with new baselines only for files
   not yet reached - no repeats, no reset.
5. `PRAGMA integrity_check` -> `ok`, `PRAGMA journal_mode` -> `wal`, after
   every run above including the Ctrl-C'd one.
6. A real `sync` (fresh scratch manifest, `jbod-test-1` registered with its
   real marker serial, a two-folder scratch NAS source) placed and copied
   both folders onto `jbod-test-1`, `status` and the dashboard read the WAL
   manifest back with no errors. Cleaned up afterward (test folders and the
   scratch `.easy_sync/manifest.sqlite3`/`config.yml` copies removed from the
   drive; its real `drive.json` marker was left untouched).
7. Confirmed by grep across every log produced above: every line either
   starts with a drive name or is one of the run's own fixed header/footer
   lines.
