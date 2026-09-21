# frozen_string_literal: true

require 'find'
require 'digest'

module EasySync
  module Jbod
    # `easy_sync scrub`: reads every tracked file on one mounted drive back off
    # the platter and compares it to its SHA-256 baseline, so bit rot is caught
    # before it gets uploaded to the offsite backup as a "change". Read-only on
    # the drive - it only ever writes to the manifest. See
    # docs/integrity-scan.md for the full design.
    class Scrubber
      NOCACHE_CMD = 48   # F_NOCACHE, macOS only; best effort elsewhere
      CHUNK_SIZE = 8 * 1024 * 1024
      COMMIT_INTERVAL = 30   # seconds; also committed on exit, including Ctrl-C

      Result = Struct.new(:drive, :baselined, :ok, :repaired, :corrupt, :unreadable, :unresolved, :removed, :changed,
                          :bytes_read, :elapsed_seconds, :stopped_reason, keyword_init: true) do
        def initialize(**)
          super
          %i[baselined ok repaired corrupt unreadable unresolved removed changed].each { |m| self[m] ||= 0 }
          self.bytes_read ||= 0
          self.elapsed_seconds ||= 0.0
        end

        def completed? = stopped_reason.nil?
        def findings? = corrupt.positive? || unreadable.positive? || unresolved.positive?
        def mb_per_s = elapsed_seconds.to_f.zero? ? 0.0 : (bytes_read.to_f / elapsed_seconds) / (1024 * 1024)
      end

      def initialize(manifest, excludes: [], clock: Time, out: $stdout, deadline: nil, dry_run: false)
        @manifest = manifest
        @excludes = Array(excludes)
        @clock = clock
        @out = out
        @deadline = deadline
        @dry_run = dry_run
      end

      # +mounted_drive+ is a MountedDrive struct. Returns a Result.
      def run(mounted_drive)
        drive_serial = mounted_drive.serial_number
        mount_point = mounted_drive.mount_point
        started = @clock.now
        result = Result.new(drive: mounted_drive.friendly_name)
        folders = @manifest.folders_on(drive_serial)

        if @dry_run
          dry_walk(drive_serial, mount_point, folders, result)
        else
          walk(drive_serial, mount_point, folders, result)
          hash_phase(drive_serial, mount_point, result) unless result.stopped_reason
        end
        result.elapsed_seconds = @clock.now - started
        report(result) unless @dry_run
        result
      end

      private

      # -- 1a: reconcile (walk) --------------------------------------------

      # A folder is only reconciled from a walk that completed: reconciling a
      # partial list would delete the rows (and baselines) of every file the
      # walk never reached, and re-baseline them later from whatever is on
      # disk by then - hiding any rot in between.
      def walk(drive_serial, mount_point, folders, result)
        folders.each do |folder|
          root = File.join(mount_point, folder.folder_path)
          next unless Dir.exist?(root)

          found = walk_folder(root)
          unless marker_present?(mount_point)
            result.stopped_reason = :unmounted
            return
          end
          if found.nil?
            @out.puts "WARNING: #{folder.folder_path}: could not walk it completely; its tracked files were left as they were"
            next
          end

          _added, removed, changed = @manifest.reconcile_checksums(drive_serial, folder.folder_path, found)
          result.removed += removed
          result.changed += changed
        end
        @manifest.prune_checksums(drive_serial, folders.map(&:folder_path))
      end

      # {relative_path => [size_bytes, mtime]} for every regular file under
      # +root+, skipping symlinks and anything matching an exclude pattern
      # (pruned, so an excluded directory's contents are never even visited).
      # nil if the walk could not finish (a directory vanished or could not be
      # read); a single file vanishing mid-walk is just left out.
      def walk_folder(root)
        found = {}
        Find.find(root, ignore_error: false) do |path|
          next if path == root

          name = File.basename(path)
          next Find.prune if excluded?(name)

          begin
            stat = File.lstat(path)
          rescue Errno::ENOENT
            next
          end
          next Find.prune if stat.symlink?

          found[path.delete_prefix("#{root}/")] = [stat.size, stat.mtime.to_i] if stat.file?
        end
        found
      rescue SystemCallError
        nil
      end

      def excluded?(name)
        @excludes.any? { |pat| File.fnmatch(pat, name, File::FNM_DOTMATCH) }
      end

      # -- 1b/1c: work queue, hash, record ---------------------------------

      def hash_phase(drive_serial, mount_point, result)
        rows = @manifest.checksum_frontier(drive_serial)
        return if rows.empty?

        db = @manifest.db
        db.transaction
        last_commit = @clock.now
        begin
          rows.each do |row|
            # One clock read per file: reused for the deadline check, the
            # commit-interval check and the timestamp written to the row, so
            # a test (or a real clock) only has to advance once per file.
            t = @clock.now
            if @deadline && t >= @deadline
              result.stopped_reason = :deadline
              break
            end
            unless marker_present?(mount_point)
              result.stopped_reason = :unmounted
              break
            end
            if hash_one(drive_serial, mount_point, row, result, at: t.utc.iso8601) == :unmounted
              result.stopped_reason = :unmounted
              break
            end
            if t - last_commit >= COMMIT_INTERVAL
              db.commit
              db.transaction
              last_commit = t
            end
          end
        ensure
          db.commit if db.transaction_active?
        end
      end

      def marker_present?(mount_point)
        File.file?(File.join(mount_point, MARKER_FILE))
      end

      # Returns :unmounted, leaving the row untouched, when the read failed
      # because the drive went away mid-file: that says nothing about the
      # file. Any other unexpected error skips just this file.
      def hash_one(drive_serial, mount_point, row, result, at:)
        path = File.join(mount_point, row.folder_path, row.relative_path)
        begin
          hex, bytes = sha256_of(path)
        rescue SystemCallError => e
          return :unmounted unless marker_present?(mount_point)

          case e
          when Errno::ENOENT
            @manifest.checksum_hashed(drive_serial, row.folder_path, row.relative_path, outcome: :vanished)
          when Errno::EIO
            record_read_error(drive_serial, row, result, at: at)
          else
            @out.puts "WARNING: #{row.label}: #{e.message}; skipped, left as it was"
          end
          return
        end
        result.bytes_read += bytes
        record_hash(drive_serial, row, hex, result, at: at)
      end

      def sha256_of(path)
        digest = Digest::SHA256.new
        bytes = 0
        File.open(path, 'rb') do |io|
          begin
            io.fcntl(NOCACHE_CMD, 1)
          rescue SystemCallError, NotImplementedError
            nil # best effort: not every filesystem/platform supports F_NOCACHE
          end
          PageCache.evict(io)
          while (chunk = io.read(CHUNK_SIZE))
            digest.update(chunk)
            bytes += chunk.bytesize
          end
        end
        [digest.hexdigest, bytes]
      end

      # A row reaches the frontier with status <> 'ok' only when it has
      # already been refetched by sync (see Manifest#checksum_frontier), so
      # that alone tells us this hash is confirming a repair, not a first
      # check.
      def record_hash(drive_serial, row, digest, result, at:)
        repair_check = !row.ok?
        if row.digest.nil?
          # A flagged row with no digest was unreadable on its very first
          # read; its first good read is a repair, which also clears the flags.
          outcome = repair_check ? :repaired : :baseline
          @manifest.checksum_hashed(drive_serial, row.folder_path, row.relative_path, outcome: outcome, digest: digest, at: at)
          repair_check ? (result.repaired += 1) : (result.baselined += 1)
        elsif digest == row.digest
          outcome = repair_check ? :repaired : :confirmed
          @manifest.checksum_hashed(drive_serial, row.folder_path, row.relative_path, outcome: outcome, digest: digest, at: at)
          repair_check ? (result.repaired += 1) : (result.ok += 1)
        elsif repair_check
          @manifest.checksum_hashed(drive_serial, row.folder_path, row.relative_path, outcome: :unresolved)
          result.unresolved += 1
        else
          @manifest.checksum_hashed(drive_serial, row.folder_path, row.relative_path, outcome: :corrupt, at: at)
          result.corrupt += 1
        end
      end

      def record_read_error(drive_serial, row, result, at:)
        if row.ok?
          @manifest.checksum_hashed(drive_serial, row.folder_path, row.relative_path, outcome: :unreadable, at: at)
          result.unreadable += 1
        else
          @manifest.checksum_hashed(drive_serial, row.folder_path, row.relative_path, outcome: :unresolved)
          result.unresolved += 1
        end
      end

      # -- dry run ----------------------------------------------------------

      # Walks and reports what a real run would add/drop/reset, plus the
      # current hash queue (an approximation: it reads the frontier as it
      # stands now, not as the walk above would leave it). Touches nothing.
      def dry_walk(drive_serial, mount_point, folders, result)
        added = removed = changed = 0
        folders.each do |folder|
          root = File.join(mount_point, folder.folder_path)
          next unless Dir.exist?(root)

          found = walk_folder(root) or next
          existing = @manifest.checksum_rows(drive_serial, folder.folder_path).to_h { |r| [r.relative_path, r] }
          found.each do |rel, (size, mtime)|
            row = existing[rel]
            if row.nil?
              added += 1
            elsif row.size_bytes != size || row.mtime != mtime
              changed += 1
            end
          end
          existing.each_key { |rel| removed += 1 unless found.key?(rel) }
        end

        frontier = @manifest.checksum_frontier(drive_serial)
        bytes = frontier.sum { |r| r.size_bytes.to_i }
        @out.puts "DRY RUN #{result.drive}: would add #{added}, drop #{removed}, reset #{changed} tracked file" \
                  "#{'s' if (added + removed + changed) != 1}; would hash #{frontier.size} file#{'s' if frontier.size != 1} " \
                  "(#{Placement.format_bytes(bytes)}), about #{Placement.format_duration(bytes / (150.0 * 1024 * 1024))} at 150 MB/s"
      end

      # -- reporting ----------------------------------------------------------

      def report(result)
        @out.puts "#{result.drive}: #{result.baselined} new baseline#{'s' if result.baselined != 1}, #{result.ok} ok, " \
                  "#{result.repaired} repaired, #{result.corrupt} CORRUPT, #{result.unreadable} UNREADABLE, " \
                  "#{result.unresolved} UNRESOLVED, #{result.removed} removed, #{result.changed} changed " \
                  "(#{Placement.format_bytes(result.bytes_read)} read, #{format('%.1f', result.mb_per_s)} MB/s)"
        case result.stopped_reason
        when :deadline then @out.puts "  stopped: --for deadline reached; the next scrub of #{result.drive} continues from here"
        when :unmounted then @out.puts "  stopped: #{result.drive} was unmounted mid-run"
        end
      end
    end
  end
end
