# frozen_string_literal: true

require 'sqlite3'
require 'fileutils'
require 'time'

module EasySync
  module Jbod
    # SQLite manifest: which folder lives on which drive, plus history.
    class Manifest
      SCHEMA_VERSION = 4

      class DuplicateFolder < Error; end
      class UnknownDrive < Error; end
      class UnknownFolder < Error; end

      def self.open(path)
        FileUtils.mkdir_p(File.dirname(path)) unless path == ':memory:'
        new(SQLite3::Database.new(path))
      end

      attr_reader :db

      def initialize(db, clock: Time)
        @db = db
        @clock = clock
        db.results_as_hash = true
        db.execute('PRAGMA foreign_keys = ON')
        migrate!
      end

      def close = db.close

      # Writes a consistent copy of the whole database to +path+ using
      # SQLite's online backup API, safe while this connection is open.
      def backup_to(path)
        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.tmp"
        File.delete(tmp) if File.exist?(tmp)
        dest = SQLite3::Database.new(tmp)
        begin
          backup = SQLite3::Backup.new(dest, 'main', db, 'main')
          backup.step(-1)
          backup.finish
        ensure
          dest.close
        end
        File.rename(tmp, path)
        path
      end

      # -- drives ---------------------------------------------------------

      def register_drive(serial_number:, friendly_name:, capacity_bytes:, volume_uuid: nil, model: nil, added_date: now)
        db.execute(<<~SQL, [serial_number, friendly_name, capacity_bytes, added_date, volume_uuid, model])
          INSERT INTO drives (serial_number, friendly_name, capacity_bytes, added_date, volume_uuid, model)
          VALUES (?, ?, ?, ?, ?, ?)
        SQL
        drive(serial_number)
      end

      # Active drives by default; a retired drive is never placed on or written to.
      def drives(include_retired: false)
        sql = 'SELECT * FROM drives'
        sql += ' WHERE retired_at IS NULL' unless include_retired
        db.execute("#{sql} ORDER BY friendly_name").map { |row| row_to_drive(row) }
      end

      # friendly_name is cosmetic (drives are matched by serial, never by
      # name or mount path), so this is a plain rename.
      def rename_drive(serial_number, new_name)
        ensure_drive!(serial_number)
        db.execute('UPDATE drives SET friendly_name = ? WHERE serial_number = ?', [new_name, serial_number])
        drive(serial_number)
      end

      # friendly_name is UNIQUE, so exchanging two names needs a temporary
      # third value to avoid colliding with the other row mid-swap.
      def swap_drive_names(serial_a, serial_b)
        a = drive(serial_a) or raise UnknownDrive, "no drive registered with serial #{serial_a}"
        b = drive(serial_b) or raise UnknownDrive, "no drive registered with serial #{serial_b}"
        db.transaction do
          db.execute('UPDATE drives SET friendly_name = ? WHERE serial_number = ?', ["__renaming__#{serial_a}", serial_a])
          db.execute('UPDATE drives SET friendly_name = ? WHERE serial_number = ?', [a.friendly_name, serial_b])
          db.execute('UPDATE drives SET friendly_name = ? WHERE serial_number = ?', [b.friendly_name, serial_a])
        end
        [drive(serial_a), drive(serial_b)]
      end

      # Marks a drive retired. Its row and history stay so old placements
      # remain answerable; #drives no longer returns it.
      def retire_drive(serial_number, at: now)
        ensure_drive!(serial_number)
        db.execute('UPDATE drives SET retired_at = ? WHERE serial_number = ?', [at, serial_number])
        drive(serial_number)
      end

      # Moves every folder on +from_serial+ to +to_serial+ (recording each), or
      # when +to_serial+ is nil removes their rows so the next sync places them
      # afresh. Returns the folder paths affected.
      def move_all_folders(from_serial, to_serial, note:, at: now)
        paths = folders_on(from_serial).map(&:folder_path)
        paths.each do |path|   # each call is its own transaction; SQLite cannot nest them
          if to_serial
            # schedule_cleanup: false - the old drive is retired right after
            # this (see #replace_drive), so its leftover data is already the
            # operator's problem, not something Purger should chase.
            reassign_folder(path, to_serial, note: note, at: at, schedule_cleanup: false)
          else
            clear_pending(path)
            remove_folder(path, note: note, at: at)
          end
        end
        paths
      end

      def drive(serial_number)
        row = db.get_first_row('SELECT * FROM drives WHERE serial_number = ?', [serial_number])
        row && row_to_drive(row)
      end

      def drive_by_name(friendly_name)
        row = db.get_first_row('SELECT * FROM drives WHERE friendly_name = ?', [friendly_name])
        row && row_to_drive(row)
      end

      def update_drive_usage(serial_number, used_bytes:, free_bytes:, capacity_bytes: nil, seen_at: now)
        ensure_drive!(serial_number)
        db.execute(<<~SQL, [used_bytes, free_bytes, seen_at, capacity_bytes, serial_number])
          UPDATE drives
             SET last_used_bytes = ?, last_free_bytes = ?, last_seen_at = ?,
                 capacity_bytes = COALESCE(?, capacity_bytes)
           WHERE serial_number = ?
        SQL
        drive(serial_number)
      end

      # power_on_hours is only ever COALESCEd in, never cleared: not every
      # health source reports it (the diskutil fallback can't), and a health
      # check that happens not to find it shouldn't erase a value read before.
      def update_drive_health(serial_number, status:, detail:, power_on_hours: nil, checked_at: now)
        ensure_drive!(serial_number)
        db.execute(<<~SQL, [status, detail, checked_at, power_on_hours, serial_number])
          UPDATE drives
             SET smart_status = ?, smart_detail = ?, smart_checked_at = ?,
                 power_on_hours = COALESCE(?, power_on_hours)
           WHERE serial_number = ?
        SQL
        drive(serial_number)
      end

      # -- SMART trend history ---------------------------------------------

      # Records one reading's reallocated-sector count for trend comparison.
      # Every check is stored, not just changes, so #reallocated_baseline has
      # a first-ever value to fall back on for a drive that's never been
      # through #verify_drive_stable.
      def record_smart_check(serial_number, reallocated_sector_ct:, checked_at: now)
        ensure_drive!(serial_number)
        db.execute(<<~SQL, [serial_number, checked_at, reallocated_sector_ct])
          INSERT INTO smart_checks (drive_serial, checked_at, reallocated_sector_ct, verified)
          VALUES (?, ?, ?, 0)
        SQL
      end

      def latest_smart_check(serial_number)
        db.get_first_row(<<~SQL, [serial_number])
          SELECT * FROM smart_checks WHERE drive_serial = ? ORDER BY checked_at DESC, id DESC LIMIT 1
        SQL
      end

      # A full-surface scan (SpinRite or equivalent) found no new defects:
      # record the drive's most recently read reallocated count as a manually
      # verified checkpoint. #reallocated_baseline compares against this
      # value and this timestamp from now on, until the next verification.
      def verify_drive_stable(serial_number, note: nil, at: now)
        ensure_drive!(serial_number)
        latest = latest_smart_check(serial_number) or
          raise Error, "no SMART check recorded yet for #{serial_number}; run a sync first"
        db.execute(<<~SQL, [serial_number, at, latest['reallocated_sector_ct'], note])
          INSERT INTO smart_checks (drive_serial, checked_at, reallocated_sector_ct, verified, note)
          VALUES (?, ?, ?, 1, ?)
        SQL
      end

      # The reallocated-sector count a new check is compared against: the
      # most recent manually verified checkpoint, or - until the first
      # verification - the earliest check ever recorded for the drive. That
      # fallback matters so turning this tracking on for an already-degraded
      # drive doesn't itself read as "the count just increased".
      def reallocated_baseline(serial_number)
        row = db.get_first_row(<<~SQL, [serial_number])
          SELECT reallocated_sector_ct FROM smart_checks
           WHERE drive_serial = ? AND verified = 1
           ORDER BY checked_at DESC, id DESC LIMIT 1
        SQL
        row ||= db.get_first_row(<<~SQL, [serial_number])
          SELECT reallocated_sector_ct FROM smart_checks
           WHERE drive_serial = ?
           ORDER BY checked_at ASC, id ASC LIMIT 1
        SQL
        row && row['reallocated_sector_ct']
      end

      # Backfills the model for a drive registered before this field existed,
      # or one whose enclosure didn't expose it at registration time.
      def update_drive_model(serial_number, model:)
        ensure_drive!(serial_number)
        db.execute('UPDATE drives SET model = ? WHERE serial_number = ?', [model, serial_number])
        drive(serial_number)
      end

      # -- folders --------------------------------------------------------

      def folders
        db.execute('SELECT * FROM folders ORDER BY folder_path').map { |row| row_to_folder(row) }
      end

      def folders_on(serial_number)
        db.execute('SELECT * FROM folders WHERE drive_serial = ? ORDER BY folder_path', [serial_number])
          .map { |row| row_to_folder(row) }
      end

      def folder(folder_path)
        row = db.get_first_row('SELECT * FROM folders WHERE folder_path = ?', [folder_path])
        row && row_to_folder(row)
      end

      # First-time placement of a folder. Writes the assignment and a history row.
      def assign_folder(folder_path, drive_serial, size_bytes: nil, note: nil, at: now)
        ensure_drive!(drive_serial)
        raise DuplicateFolder, "#{folder_path} is already assigned" if folder(folder_path)

        db.transaction do
          db.execute(<<~SQL, [folder_path, drive_serial, size_bytes, at])
            INSERT INTO folders (folder_path, drive_serial, size_bytes, assigned_at) VALUES (?, ?, ?, ?)
          SQL
          record_history(folder_path, drive_serial, 'assigned', note, at)
        end
        folder(folder_path)
      end

      # Records that a folder now lives on another drive. Does not move data,
      # so whatever is already on the old drive is scheduled for cleanup
      # (cause 'reassigned') rather than left there untracked: Purger only
      # removes it once the folder has actually synced OK to its new drive
      # (see Purger#ready?) and the usual grace period has passed.
      # +schedule_cleanup: false+ is for callers (replace-drive) that retire
      # the old drive right after, where that drive's leftover data is
      # already understood to be the operator's problem, not tracked here.
      def reassign_folder(folder_path, new_drive_serial, note: nil, at: now, schedule_cleanup: true)
        ensure_drive!(new_drive_serial)
        current = folder(folder_path) or raise UnknownFolder, "#{folder_path} is not in the manifest"
        return current if current.drive_serial == new_drive_serial

        db.transaction do
          db.execute(<<~SQL, [new_drive_serial, at, folder_path])
            UPDATE folders SET drive_serial = ?, assigned_at = ?, last_synced_at = NULL, last_sync_status = NULL
             WHERE folder_path = ?
          SQL
          record_history(folder_path, new_drive_serial, 'reassigned',
                         note || "moved from #{current.drive_serial}", at)
          if schedule_cleanup
            # missing_runs is set far above any real grace_runs: 'reassigned'
            # has no repeated-probe concept to confirm (unlike
            # 'missing_on_nas'), so PendingDeletion#expired?'s run-count half
            # is always satisfied here on purpose. The real gates are
            # expires_at (grace_days) below, plus Purger#ready? requiring a
            # verified sync to the new drive.
            db.execute(<<~SQL, [folder_path, current.drive_serial, current.drive_serial, at, at])
              INSERT INTO pending_deletions (folder_path, relative_path, kind, drive_serial, cause,
                                             first_missing_at, last_missing_at, missing_runs)
              VALUES (?, ?, 'folder', ?, 'reassigned', ?, ?, 1000000)
            SQL
          end
        end
        folder(folder_path)
      end

      def remove_folder(folder_path, note: nil, at: now)
        current = folder(folder_path) or raise UnknownFolder, "#{folder_path} is not in the manifest"
        db.transaction do
          db.execute('DELETE FROM folders WHERE folder_path = ?', [folder_path])
          record_history(folder_path, current.drive_serial, 'removed', note, at)
        end
        current
      end

      def mark_folder_status(folder_path, status, at: now)
        db.execute('UPDATE folders SET last_sync_status = ? WHERE folder_path = ?', [status, folder_path])
        folder(folder_path)
      end

      # -- history --------------------------------------------------------

      def history(folder_path = nil, limit: nil)
        sql = 'SELECT * FROM placement_history'
        params = []
        if folder_path
          sql += ' WHERE folder_path = ?'
          params << folder_path
        end
        sql += ' ORDER BY id DESC'
        if limit
          sql += ' LIMIT ?'
          params << limit
        end
        db.execute(sql, params).map { |row| HistoryEntry.new(**symbolize(row)) }
      end

      # -- sync runs ------------------------------------------------------

      def record_sync(folder_path:, drive_serial:, started_at:, finished_at:, exit_status:,
                      bytes_transferred: nil, total_size_bytes: nil)
        status = exit_status.zero? ? 'ok' : 'failed'
        params = [folder_path, drive_serial, started_at, finished_at, exit_status, bytes_transferred, total_size_bytes]
        db.transaction do
          db.execute(<<~SQL, params)
            INSERT INTO sync_runs (folder_path, drive_serial, started_at, finished_at, exit_status,
                                   bytes_transferred, total_size_bytes)
            VALUES (?, ?, ?, ?, ?, ?, ?)
          SQL
          if exit_status.zero?
            db.execute(<<~SQL, [finished_at, status, total_size_bytes, folder_path])
              UPDATE folders SET last_synced_at = ?, last_sync_status = ?,
                                 size_bytes = COALESCE(?, size_bytes)
               WHERE folder_path = ?
            SQL
          else
            db.execute('UPDATE folders SET last_sync_status = ? WHERE folder_path = ?', [status, folder_path])
          end
        end
        folder(folder_path)
      end

      def sync_runs(folder_path: nil, limit: 50)
        sql = 'SELECT * FROM sync_runs'
        params = []
        if folder_path
          sql += ' WHERE folder_path = ?'
          params << folder_path
        end
        sql += ' ORDER BY id DESC LIMIT ?'
        params << limit
        db.execute(sql, params).map { |row| SyncRun.new(**symbolize(row)) }
      end

      # Every successful sync_run since +since+ (ISO8601), oldest first, no
      # LIMIT: for estimating a run in progress, which can touch thousands
      # of folders, unlike #sync_runs' recent-activity display.
      def sync_runs_since(since)
        db.execute('SELECT * FROM sync_runs WHERE started_at >= ? AND exit_status = 0 ORDER BY id', [since])
          .map { |row| SyncRun.new(**symbolize(row)) }
      end

      # -- source inventory ----------------------------------------------

      # Replaces the inventory with what this run saw. +rows+ are hashes with
      # folder_path, size_bytes, state ('placed' | 'unplaced' | 'empty'), detail.
      def replace_source_inventory(rows, at: now)
        db.transaction do
          db.execute('DELETE FROM source_inventory')
          rows.each do |r|
            db.execute('INSERT INTO source_inventory (folder_path, size_bytes, state, detail, seen_at) VALUES (?, ?, ?, ?, ?)',
                       [r[:folder_path], r[:size_bytes], r[:state], r[:detail], at])
          end
        end
      end

      def source_inventory
        db.execute('SELECT * FROM source_inventory ORDER BY folder_path').map { |row| SourceEntry.new(**symbolize(row)) }
      end

      # -- pending deletions ----------------------------------------------

      # Replaces the candidate set for +folder_path+ with +missing+, an array of
      # [relative_path, kind] pairs reported by rsync this run. Paths seen before
      # keep their first_missing_at and get their run counter bumped; paths no
      # longer reported have reappeared on the NAS and are forgotten.
      # Returns { new:, still:, reappeared: } counts.
      def reconcile_pending(folder_path, missing, at: now)
        existing = pending_deletions(folder_path: folder_path).select { |p| !p.reassigned? }.to_h { |p| [p.relative_path, p] }
        keys = missing.map(&:first)
        counts = { new: 0, still: 0, reappeared: 0 }
        drive_serial = folder(folder_path)&.drive_serial
        db.transaction do
          existing.each_key do |rel|
            next if keys.include?(rel)

            db.execute("DELETE FROM pending_deletions WHERE folder_path = ? AND relative_path = ? AND cause = 'missing_on_nas'",
                       [folder_path, rel])
            counts[:reappeared] += 1
          end
          missing.each do |rel, kind|
            if existing[rel]
              db.execute(<<~SQL, [at, kind, drive_serial, folder_path, rel])
                UPDATE pending_deletions SET last_missing_at = ?, missing_runs = missing_runs + 1, kind = ?, drive_serial = ?
                 WHERE folder_path = ? AND relative_path = ? AND cause = 'missing_on_nas'
              SQL
              counts[:still] += 1
            else
              db.execute(<<~SQL, [folder_path, rel, kind, drive_serial, at, at])
                INSERT INTO pending_deletions (folder_path, relative_path, kind, drive_serial, cause,
                                               first_missing_at, last_missing_at, missing_runs)
                VALUES (?, ?, ?, ?, 'missing_on_nas', ?, ?, 1)
              SQL
              counts[:new] += 1
            end
          end
        end
        counts
      end

      def pending_deletions(folder_path: nil)
        sql = 'SELECT * FROM pending_deletions'
        params = []
        if folder_path
          sql += ' WHERE folder_path = ?'
          params << folder_path
        end
        sql += ' ORDER BY folder_path, relative_path'
        db.execute(sql, params).map { |row| PendingDeletion.new(**symbolize(row)) }
      end

      def expired_deletions(now:, grace_days:, grace_runs:)
        pending_deletions.select { |p| p.expired?(now: now, grace_days: grace_days, grace_runs: grace_runs) }
      end

      # Moves a candidate into the audit log once it has actually been removed.
      def record_deletion(pending, drive_serial:, at: now)
        params = [pending.folder_path, pending.relative_path, pending.kind, drive_serial, pending.first_missing_at, at]
        db.transaction do
          db.execute(<<~SQL, params)
            INSERT INTO deletions (folder_path, relative_path, kind, drive_serial, first_missing_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?)
          SQL
          db.execute('DELETE FROM pending_deletions WHERE id = ?', [pending.id])
        end
      end

      # Audit row for something `clean` removed: excluded junk, gone right away.
      def record_cleaned(folder_path:, relative_path:, kind:, drive_serial:, at: now)
        db.execute(<<~SQL, [folder_path, relative_path, kind, drive_serial, at, at])
          INSERT INTO deletions (folder_path, relative_path, kind, drive_serial, first_missing_at, deleted_at)
          VALUES (?, ?, ?, ?, ?, ?)
        SQL
      end

      # Drops pending rows whose path has any segment matching one of +patterns+
      # (shell globs): excluded junk never needs a grace period, on disk or not.
      def forget_pending_matching(patterns)
        pending_deletions.each do |p|
          segments = p.relative_path.split('/')
          next unless segments.any? { |seg| patterns.any? { |pat| File.fnmatch?(pat, seg, File::FNM_DOTMATCH) } }

          db.execute('DELETE FROM pending_deletions WHERE id = ?', [p.id])
        end
      end

      def clear_pending(folder_path)
        db.execute('DELETE FROM pending_deletions WHERE folder_path = ?', [folder_path])
      end

      def deletions(limit: 50)
        db.execute('SELECT * FROM deletions ORDER BY id DESC LIMIT ?', [limit]).map { |row| Deletion.new(**symbolize(row)) }
      end

      def schema_version
        db.get_first_value('PRAGMA user_version')
      end

      # -- file checksums (scrub) ------------------------------------------

      def checksum_rows(drive_serial, folder_path)
        db.execute('SELECT * FROM file_checksums WHERE drive_serial = ? AND folder_path = ?', [drive_serial, folder_path])
          .map { |row| row_to_checksum(row) }
      end

      # Reconciles one folder's rows against +found+, a hash of
      # relative_path => [size_bytes, mtime] from a walk of the drive. A file
      # with no row is inserted (digest NULL). A row whose file is gone is
      # deleted. A row whose size or mtime differs is reset to a fresh,
      # unhashed baseline (a legitimate re-sync, not rot). One transaction.
      # Returns [added, removed, changed].
      def reconcile_checksums(drive_serial, folder_path, found)
        existing = checksum_rows(drive_serial, folder_path).to_h { |r| [r.relative_path, r] }
        added = removed = changed = 0
        db.transaction do
          found.each do |rel, (size, mtime)|
            row = existing[rel]
            if row.nil?
              db.execute(<<~SQL, [drive_serial, folder_path, rel, size, mtime])
                INSERT INTO file_checksums (drive_serial, folder_path, relative_path, size_bytes, mtime)
                VALUES (?, ?, ?, ?, ?)
              SQL
              added += 1
            elsif row.size_bytes != size || row.mtime != mtime
              db.execute(<<~SQL, [size, mtime, drive_serial, folder_path, rel])
                UPDATE file_checksums
                   SET size_bytes = ?, mtime = ?, digest = NULL, verified_at = NULL, failed_at = NULL, refetched_at = NULL,
                       status = 'ok'
                 WHERE drive_serial = ? AND folder_path = ? AND relative_path = ?
              SQL
              changed += 1
            end
          end
          existing.each_key do |rel|
            next if found.key?(rel)

            db.execute('DELETE FROM file_checksums WHERE drive_serial = ? AND folder_path = ? AND relative_path = ?',
                       [drive_serial, folder_path, rel])
            removed += 1
          end
        end
        [added, removed, changed]
      end

      # Drops +drive_serial+'s rows for folders no longer in +keep_folder_paths+
      # (the folder was reassigned, removed, or purged off this drive).
      def prune_checksums(drive_serial, keep_folder_paths)
        if keep_folder_paths.empty?
          db.execute('DELETE FROM file_checksums WHERE drive_serial = ?', [drive_serial])
        else
          placeholders = keep_folder_paths.map { '?' }.join(',')
          db.execute("DELETE FROM file_checksums WHERE drive_serial = ? AND folder_path NOT IN (#{placeholders})",
                     [drive_serial, *keep_folder_paths])
        end
      end

      # The hashing work queue: 'ok' rows (already-hashed ones are due for
      # periodic re-verification too) plus flagged rows sync has refetched,
      # ordered refetched-repairs first, then never-hashed, then oldest
      # verified first. A flagged row still awaiting refetch, or 'unresolved',
      # is never returned: re-hashing it proves nothing new.
      def checksum_frontier(drive_serial)
        db.execute(<<~SQL, [drive_serial]).map { |row| row_to_checksum(row) }
          SELECT * FROM file_checksums
           WHERE drive_serial = ?
             AND (status = 'ok'
                  OR (status IN ('corrupt','unreadable') AND refetched_at IS NOT NULL))
           ORDER BY
             CASE WHEN status <> 'ok'   THEN 0
                  WHEN digest IS NULL   THEN 1
                  ELSE 2 END,
             verified_at, folder_path, relative_path
        SQL
      end

      # Records the outcome of hashing one file. +outcome+ is one of
      # :baseline (first-ever hash), :confirmed (matches), :corrupt (differs),
      # :unreadable (Errno::EIO), :repaired (a flagged+refetched row now
      # matches, or got its first successful read), :unresolved (a
      # flagged+refetched row still bad), :vanished (Errno::ENOENT: row
      # deleted). The digest is kept, not cleared, when marking corrupt: it is
      # the known-good baseline a later repair is checked against.
      def checksum_hashed(drive_serial, folder_path, relative_path, outcome:, digest: nil, at: now)
        key = [drive_serial, folder_path, relative_path]
        case outcome
        when :baseline
          db.execute('UPDATE file_checksums SET digest = ?, verified_at = ? WHERE drive_serial = ? AND folder_path = ? AND relative_path = ?',
                     [digest, at, *key])
        when :confirmed
          db.execute('UPDATE file_checksums SET verified_at = ? WHERE drive_serial = ? AND folder_path = ? AND relative_path = ?',
                     [at, *key])
        when :corrupt
          db.execute("UPDATE file_checksums SET status = 'corrupt', failed_at = ? WHERE drive_serial = ? AND folder_path = ? AND relative_path = ?",
                     [at, *key])
        when :unreadable
          db.execute("UPDATE file_checksums SET status = 'unreadable', failed_at = ? WHERE drive_serial = ? AND folder_path = ? AND relative_path = ?",
                     [at, *key])
        when :repaired
          db.execute(<<~SQL, [digest, at, *key])
            UPDATE file_checksums
               SET status = 'ok', digest = COALESCE(?, digest), verified_at = ?, failed_at = NULL, refetched_at = NULL
             WHERE drive_serial = ? AND folder_path = ? AND relative_path = ?
          SQL
        when :unresolved
          db.execute("UPDATE file_checksums SET status = 'unresolved' WHERE drive_serial = ? AND folder_path = ? AND relative_path = ?",
                     key)
        when :vanished
          db.execute('DELETE FROM file_checksums WHERE drive_serial = ? AND folder_path = ? AND relative_path = ?', key)
        else
          raise ArgumentError, "unknown checksum outcome #{outcome.inspect}"
        end
      end

      # Rows flagged by scrub that sync should refetch: not yet refetched
      # since being flagged. 'unresolved' rows are excluded on purpose - they
      # are never refetched again automatically.
      def flagged_checksums(drive_serial, folder_path)
        db.execute(<<~SQL, [drive_serial, folder_path]).map { |row| row_to_checksum(row) }
          SELECT * FROM file_checksums
           WHERE drive_serial = ? AND folder_path = ? AND status IN ('corrupt', 'unreadable') AND refetched_at IS NULL
           ORDER BY relative_path
        SQL
      end

      def mark_refetched(drive_serial, folder_path, relative_paths, at: now)
        relative_paths.each do |rel|
          db.execute('UPDATE file_checksums SET refetched_at = ? WHERE drive_serial = ? AND folder_path = ? AND relative_path = ?',
                     [at, drive_serial, folder_path, rel])
        end
      end

      # Every non-ok row for one folder on one drive: what `restore` warns
      # about before copying it back onto the NAS. Unlike #flagged_checksums,
      # this also includes rows already refetched or 'unresolved'.
      def scrub_findings_for(drive_serial, folder_path)
        db.execute("SELECT * FROM file_checksums WHERE drive_serial = ? AND folder_path = ? AND status <> 'ok' ORDER BY relative_path",
                   [drive_serial, folder_path]).map { |row| row_to_checksum(row) }
      end

      # Every non-ok row on an active drive, newest failure first: the
      # dashboard's "Scrub findings" section and `status`'s summary count.
      # Retired drives are left out: `scrub` refuses them, so their findings
      # could never be cleared.
      def scrub_findings
        db.execute(<<~SQL).map { |row| row_to_checksum(row) }
          SELECT c.* FROM file_checksums c JOIN drives d ON d.serial_number = c.drive_serial
           WHERE c.status <> 'ok' AND d.retired_at IS NULL
           ORDER BY c.failed_at DESC
        SQL
      end

      # The oldest verified_at across a drive's 'ok' rows: the moment since
      # which every healthy file on it has been checked. NULL if it has no
      # 'ok' rows yet, or any has never been hashed. Flagged and unresolved
      # rows are left out on purpose: they are skipped by the hash queue, so
      # their verified_at never advances, and counting them would pin the
      # drive as stalest (and overdue) forever. They are reported as findings.
      def scrubbed_through(drive_serial)
        ok = "drive_serial = ? AND status = 'ok'"
        return nil if db.get_first_value("SELECT COUNT(*) FROM file_checksums WHERE #{ok}", [drive_serial]).zero?
        return nil if db.get_first_value("SELECT COUNT(*) FROM file_checksums WHERE #{ok} AND digest IS NULL", [drive_serial]).positive?

        db.get_first_value("SELECT MIN(verified_at) FROM file_checksums WHERE #{ok}", [drive_serial])
      end

      private

      def now = @clock.now.utc.iso8601

      def ensure_drive!(serial_number)
        drive(serial_number) or raise UnknownDrive, "no drive registered with serial #{serial_number}"
      end

      def record_history(folder_path, drive_serial, event, note, at)
        db.execute(<<~SQL, [folder_path, drive_serial, event, at, note])
          INSERT INTO placement_history (folder_path, drive_serial, event, recorded_at, note)
          VALUES (?, ?, ?, ?, ?)
        SQL
      end

      def row_to_drive(row) = Drive.new(**symbolize(row))
      def row_to_folder(row) = Folder.new(**symbolize(row))
      def row_to_checksum(row) = FileChecksum.new(**symbolize(row))

      def symbolize(row)
        row.to_h.transform_keys(&:to_sym)
      end

      # Columns added after v1 are applied by checking for them, never by
      # comparing user_version: the real manifest was stamped 5 by pre-2.0
      # builds, so a version-gated ALTER silently never ran on it.
      def migrate!
        migrate_to_v1! if schema_version < 1
        add_column('drives', 'model', 'TEXT')
        add_column('drives', 'power_on_hours', 'INTEGER')
        create_smart_checks_table!
        # CREATE TABLE IF NOT EXISTS first: add_column assumes its table
        # already exists, which migrate_to_v1! only guarantees when it
        # actually ran (schema_version < 1). A real manifest can be older
        # than this tool and already have pending_deletions without these
        # columns, so add_column still does the column-level check too.
        create_pending_deletions_table!
        add_column('pending_deletions', 'drive_serial', 'TEXT')
        add_column('pending_deletions', 'cause', "TEXT NOT NULL DEFAULT 'missing_on_nas'")
        create_file_checksums_table!
        db.execute("PRAGMA user_version = #{SCHEMA_VERSION}") if schema_version < SCHEMA_VERSION
      end

      def create_file_checksums_table!
        db.execute_batch(<<~SQL)
          CREATE TABLE IF NOT EXISTS file_checksums (
            drive_serial  TEXT    NOT NULL REFERENCES drives(serial_number),
            folder_path   TEXT    NOT NULL,
            relative_path TEXT    NOT NULL,
            size_bytes    INTEGER NOT NULL,
            mtime         INTEGER NOT NULL,
            digest        TEXT,
            verified_at   TEXT,
            status        TEXT    NOT NULL DEFAULT 'ok',
            failed_at     TEXT,
            refetched_at  TEXT,
            PRIMARY KEY (drive_serial, folder_path, relative_path)
          );
          CREATE INDEX IF NOT EXISTS idx_file_checksums_frontier
            ON file_checksums(drive_serial, status, verified_at);
        SQL
      end

      def create_smart_checks_table!
        db.execute_batch(<<~SQL)
          CREATE TABLE IF NOT EXISTS smart_checks (
            id                    INTEGER PRIMARY KEY AUTOINCREMENT,
            drive_serial          TEXT NOT NULL REFERENCES drives(serial_number),
            checked_at            TEXT NOT NULL,
            reallocated_sector_ct INTEGER,
            verified              INTEGER NOT NULL DEFAULT 0,
            note                  TEXT
          );
          CREATE INDEX IF NOT EXISTS idx_smart_checks_drive ON smart_checks(drive_serial, checked_at);
        SQL
      end

      def create_pending_deletions_table!
        db.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS pending_deletions (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            folder_path      TEXT NOT NULL,
            relative_path    TEXT NOT NULL,
            kind             TEXT NOT NULL,
            first_missing_at TEXT NOT NULL,
            last_missing_at  TEXT NOT NULL,
            missing_runs     INTEGER NOT NULL DEFAULT 1,
            UNIQUE (folder_path, relative_path)
          );
        SQL
      end

      def add_column(table, name, type)
        return if db.execute("PRAGMA table_info(#{table})").any? { |c| c['name'] == name }

        db.execute("ALTER TABLE #{table} ADD COLUMN #{name} #{type}")
      end

      def migrate_to_v1!
        db.transaction do
          db.execute_batch(<<~SQL)
            CREATE TABLE IF NOT EXISTS drives (
              serial_number   TEXT PRIMARY KEY,
              friendly_name   TEXT NOT NULL UNIQUE,
              capacity_bytes  INTEGER NOT NULL,
              added_date      TEXT NOT NULL,
              volume_uuid     TEXT,
              last_seen_at    TEXT,
              last_used_bytes INTEGER,
              last_free_bytes INTEGER,
              smart_status    TEXT,
              smart_detail    TEXT,
              smart_checked_at TEXT,
              retired_at      TEXT
            );

            CREATE TABLE IF NOT EXISTS folders (
              folder_path      TEXT PRIMARY KEY,
              drive_serial     TEXT NOT NULL REFERENCES drives(serial_number),
              size_bytes       INTEGER,
              assigned_at      TEXT NOT NULL,
              last_synced_at   TEXT,
              last_sync_status TEXT
            );

            CREATE TABLE IF NOT EXISTS placement_history (
              id           INTEGER PRIMARY KEY AUTOINCREMENT,
              folder_path  TEXT NOT NULL,
              drive_serial TEXT NOT NULL,
              event        TEXT NOT NULL,
              recorded_at  TEXT NOT NULL,
              note         TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_history_folder ON placement_history(folder_path);

            CREATE TABLE IF NOT EXISTS sync_runs (
              id                INTEGER PRIMARY KEY AUTOINCREMENT,
              folder_path       TEXT NOT NULL,
              drive_serial      TEXT NOT NULL,
              started_at        TEXT NOT NULL,
              finished_at       TEXT,
              exit_status       INTEGER,
              bytes_transferred INTEGER,
              total_size_bytes  INTEGER
            );
            CREATE INDEX IF NOT EXISTS idx_sync_runs_folder ON sync_runs(folder_path);

            CREATE TABLE IF NOT EXISTS pending_deletions (
              id               INTEGER PRIMARY KEY AUTOINCREMENT,
              folder_path      TEXT NOT NULL,
              relative_path    TEXT NOT NULL,
              kind             TEXT NOT NULL,
              drive_serial     TEXT,
              cause            TEXT NOT NULL DEFAULT 'missing_on_nas',
              first_missing_at TEXT NOT NULL,
              last_missing_at  TEXT NOT NULL,
              missing_runs     INTEGER NOT NULL DEFAULT 1,
              UNIQUE (folder_path, relative_path)
            );

            CREATE TABLE IF NOT EXISTS source_inventory (
              folder_path TEXT PRIMARY KEY,
              size_bytes  INTEGER,
              state       TEXT NOT NULL,
              detail      TEXT,
              seen_at     TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS deletions (
              id               INTEGER PRIMARY KEY AUTOINCREMENT,
              folder_path      TEXT NOT NULL,
              relative_path    TEXT NOT NULL,
              kind             TEXT NOT NULL,
              drive_serial     TEXT NOT NULL,
              first_missing_at TEXT NOT NULL,
              deleted_at       TEXT NOT NULL
            );
          SQL
          db.execute('PRAGMA user_version = 1')
        end
      end

    end
  end
end
