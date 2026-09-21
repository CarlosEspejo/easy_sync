# Measured performance

These numbers were measured, not estimated. Re-measure rather than eyeball.
The fleet is 8 drives, 44.59 TB (4 × 7.28, 2 × 5.46, 1 × 2.73, 1 × 1.82 TB),
against a library of about 31.9 TB (tv 17.7, movies 12.3, synology 1.9,
pro 0.04).

## Sync throughput: 62.9 MB/s aggregate

The source is the `sync_runs` table of the real manifest, for the first
full-library run (2026-09-13 to 2026-09-17). That covers 154 folder copies of
5 GB or more: 11.3 TB in 49.9 hours of transfer time. Runs under 5 GB are
left out so that per-folder setup time doesn't skew the rate.

```sql
SELECT folder_path, bytes_transferred,
       strftime('%s',finished_at) - strftime('%s',started_at) AS secs
  FROM sync_runs
 WHERE exit_status = 0 AND bytes_transferred >= 5e9
   AND strftime('%s',finished_at) > strftime('%s',started_at);
```

| statistic | MB/s |
|---|---|
| **aggregate (total bytes / total time)** | **62.9** |
| median folder | 67.7 |
| p25 – p75 | 57.8 – 79.8 |
| p10 – p90 | 50.2 – 87.6 |
| min / max | 16.6 / 98.3 |

- **Use the aggregate for planning.** It is the only figure that predicts
  wall-clock time. The median looks better because slow folders take up more
  of the clock.
- **Don't read the rate off an rsync log.** The rate `--info=progress2` prints
  is a cumulative average (bytes ÷ elapsed). It changes slowly and hides how
  much the real rate varies.
- **The floor for any change to `sync`: the aggregate must stay at or above
  50 MB/s.** It is a floor on the aggregate because 10.7% of transfer time
  already runs below 50. Hashing inside the copy path costs 25–33%, which
  would bring the aggregate down to 42–47 MB/s. That is why `scrub` is a
  separate command (see `docs/integrity-scan.md`).
- **Time Machine skews the numbers.** It backs up to a sparsebundle on the
  same Synology (DS1019) that serves the media shares, so it competes for the
  same array and SMB link. It was running during part of this run. Run
  `sudo tmutil disable` before re-measuring, and check it first whenever a
  sync looks slow.
- **The NAS read side is not measured yet**, and it is the part that limits
  speed. It needs a quiet NAS: no sync and no Time Machine running.

## Drives are not the limit

Sync throughput per target drive: backup-01-8tb 66.5, backup-03-8tb 66.8,
backup-04-8tb 66.4, backup-06-8tb 68.8, backup-02-6tb 67.8 MB/s. They are within 2.4 MB/s of each other,
because none of them is the constraint.

Each drive was also measured directly: 8 GB sequential, buffer cache bypassed
with `fcntl(F_NOCACHE)`, closing `fsync` included in the timing. The "used"
column is how full the drive was when it was measured.

| drive | model | used then | write MB/s | read MB/s |
|---|---|---|---|---|
| backup-04-8tb | ST8000VN004 | 2.2 TB | **203** | 213 |
| backup-06-8tb | ST8000VN004 | 4.1 TB | 182 | 190 |
| backup-01-8tb | ST8000VN004 | 2.5 TB | 178 | 199 |
| backup-07-6tb | HDWE160 | empty | 143 | 179 |
| backup-08-2tb | ST2000LM015 | empty | 116 | 126 |
| backup-05-3tb | WD30EFRX | empty | 115 | 128 |

The 8 TB figures are the mean of three runs; the others are single runs.
Runs vary by about ±7%, so smaller differences than that aren't real.
backup-04 really is about 14% faster than the identical backup-01, across
three runs. Even the slowest drive writes at 1.8× the sync rate.

How to benchmark a drive so the result is real:

- With 24 GB of RAM, a test smaller than RAM measures the buffer cache, not
  the disk.
- macOS `dd` has no `oflag=direct`. `io.fcntl(48, 1)` (`F_NOCACHE`) on the
  file descriptor is the only way to bypass the cache.
- A spinning drive that benchmarks in GB/s means the flag didn't take effect.
- Use random data, and include the closing `fsync` in the timing.
- Never benchmark a drive that a sync is writing to at the same time.

## Enclosure bandwidth

The OWC ThunderBay 8 is Thunderbolt, not USB-C. Each bay has its own AHCI
controller at 6 Gb/s (about 600 MB/s), on a 40 Gb/s link (about 5,000 MB/s).
`system_profiler SPSerialATADataType SPThunderboltDataType` shows the layout.
All 8 drives reading at about 190 MB/s together would use about 1,500 MB/s,
roughly 30% of the link. So scrubbing several drives in parallel would not be
limited by bandwidth, if that is ever wanted.

## Hash speed (Apple Silicon)

SHA-256 2514 MB/s, SHA-1 2486, MD5 763. Apple Silicon speeds up SHA but not
MD5. All of these are faster than any drive can read.
