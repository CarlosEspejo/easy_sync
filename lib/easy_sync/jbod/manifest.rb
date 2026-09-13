# frozen_string_literal: true

require 'sqlite3'
require 'fileutils'
require 'time'

module EasySync
  module Jbod
    # SQLite manifest: which folder lives on which drive, plus history.
    class Manifest
      SCHEMA_VERSION = 3

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

      # -- drives ---------------------------------------------------------

      def register_drive(serial_number:, friendly_name:, capacity_bytes:, volume_uuid: nil, added_date: now)
        db.execute(<<~SQL, [serial_number, friendly_name, capacity_bytes, added_date, volume_uuid])
          INSERT INTO drives (serial_number, friendly_name, capacity_bytes, added_date, volume_uuid)
          VALUES (?, ?, ?, ?, ?)
        SQL
        drive(serial_number)
      end

      def drives
        db.execute('SELECT * FROM drives ORDER BY friendly_name').map { |row| row_to_drive(row) }
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

      def update_drive_health(serial_number, status:, detail:, checked_at: now)
        ensure_drive!(serial_number)
        db.execute('UPDATE drives SET smart_status = ?, smart_detail = ?, smart_checked_at = ? WHERE serial_number = ?',
                   [status, detail, checked_at, serial_number])
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

      # Records that a folder now lives on another drive. Does not move data.
      def reassign_folder(folder_path, new_drive_serial, note: nil, at: now)
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

      # -- pending deletions ----------------------------------------------

      # Replaces the candidate set for +folder_path+ with +missing+, an array of
      # [relative_path, kind] pairs reported by rsync this run. Paths seen before
      # keep their first_missing_at and get their run counter bumped; paths no
      # longer reported have reappeared on the NAS and are forgotten.
      # Returns { new:, still:, reappeared: } counts.
      def reconcile_pending(folder_path, missing, at: now)
        existing = pending_deletions(folder_path: folder_path).to_h { |p| [p.relative_path, p] }
        keys = missing.map(&:first)
        counts = { new: 0, still: 0, reappeared: 0 }
        db.transaction do
          existing.each_key do |rel|
            next if keys.include?(rel)

            db.execute('DELETE FROM pending_deletions WHERE folder_path = ? AND relative_path = ?', [folder_path, rel])
            counts[:reappeared] += 1
          end
          missing.each do |rel, kind|
            if existing[rel]
              db.execute(<<~SQL, [at, kind, folder_path, rel])
                UPDATE pending_deletions SET last_missing_at = ?, missing_runs = missing_runs + 1, kind = ?
                 WHERE folder_path = ? AND relative_path = ?
              SQL
              counts[:still] += 1
            else
              db.execute(<<~SQL, [folder_path, rel, kind, at, at])
                INSERT INTO pending_deletions (folder_path, relative_path, kind, first_missing_at, last_missing_at, missing_runs)
                VALUES (?, ?, ?, ?, ?, 1)
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

      def clear_pending(folder_path)
        db.execute('DELETE FROM pending_deletions WHERE folder_path = ?', [folder_path])
      end

      def deletions(limit: 50)
        db.execute('SELECT * FROM deletions ORDER BY id DESC LIMIT ?', [limit]).map { |row| Deletion.new(**symbolize(row)) }
      end

      def schema_version
        db.get_first_value('PRAGMA user_version')
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

      def symbolize(row)
        row.to_h.transform_keys(&:to_sym)
      end

      def migrate!
        return if schema_version >= SCHEMA_VERSION

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
              smart_checked_at TEXT
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
              first_missing_at TEXT NOT NULL,
              last_missing_at  TEXT NOT NULL,
              missing_runs     INTEGER NOT NULL DEFAULT 1,
              UNIQUE (folder_path, relative_path)
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
          add_missing_columns('drives', smart_status: 'TEXT', smart_detail: 'TEXT', smart_checked_at: 'TEXT')
          db.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
        end
      end

      # Schema v3 added the SMART columns; a v1/v2 database gets them here.
      def add_missing_columns(table, columns)
        present = db.execute("PRAGMA table_info(#{table})").map { |r| r['name'] }
        columns.each do |name, type|
          db.execute("ALTER TABLE #{table} ADD COLUMN #{name} #{type}") unless present.include?(name.to_s)
        end
      end
    end
  end
end
