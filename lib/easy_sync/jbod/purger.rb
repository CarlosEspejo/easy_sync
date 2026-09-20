# frozen_string_literal: true

require 'fileutils'

module EasySync
  module Jbod
    # Removes expired deletion candidates from the drives. This is the only
    # code in the tool that deletes backup data, so it is deliberately narrow:
    # a candidate is removed only if its folder's drive is mounted right now,
    # the path resolves inside that folder's destination, and it has been
    # missing on the NAS for both the day and run thresholds.
    class Purger
      Result = Struct.new(:purged, :would_purge, :skipped, keyword_init: true) do
        def initialize(**)
          super
          members.each { |m| self[m] ||= [] }
        end
      end

      def initialize(manifest, grace_days:, grace_runs:, clock: Time, out: $stdout)
        @manifest = manifest
        @grace_days = grace_days
        @grace_runs = grace_runs
        @clock = clock
        @out = out
      end

      # +mounted+ are the MountedDrive structs for this run.
      def run(mounted, dry_run: false)
        by_serial = mounted.to_h { |m| [m.serial_number, m] }
        result = Result.new
        expired = @manifest.expired_deletions(now: @clock.now, grace_days: @grace_days, grace_runs: @grace_runs)
                           .select { |p| ready?(p) }

        # Whole folders first; their file-level candidates go with them.
        folders, paths = expired.partition(&:whole_folder?)
        folders.each do |pending|
          purge_one(pending, by_serial, result, dry_run: dry_run) do |dest, drive|
            FileUtils.rm_rf(dest)
            # A 'reassigned' candidate is the OLD copy of a folder that still
            # has a valid manifest row elsewhere (see #ready?); only the
            # files come out, the folder record itself must survive. A
            # 'missing_on_nas' candidate means the folder is gone entirely.
            unless pending.reassigned?
              @manifest.clear_pending(pending.folder_path)
              @manifest.remove_folder(pending.folder_path, note: "deleted from #{drive.friendly_name}: " \
                                                                 "missing on NAS since #{pending.first_missing_at}")
            end
          end
        end

        gone = folders.map(&:folder_path)
        files, dirs = paths.reject { |p| gone.include?(p.folder_path) }.partition { |p| p.kind == 'file' }
        files.each do |pending|
          purge_one(pending, by_serial, result, dry_run: dry_run) { |dest, _| File.delete(dest) if File.exist?(dest) }
        end
        # Deepest directories first so parents empty out before we reach them.
        dirs.sort_by { |p| -p.relative_path.count('/') }.each do |pending|
          purge_one(pending, by_serial, result, dry_run: dry_run) do |dest, _|
            if Dir.exist?(dest) && !Dir.empty?(dest)
              @out.puts "  leaving #{dest}: not empty yet"
              next false
            end
            Dir.rmdir(dest) if Dir.exist?(dest)
          end
        end
        result
      end

      private

      # A folder moved off a drive (cause 'reassigned') is only safe to purge
      # from there once it has actually landed, verified, on its new drive:
      # grace_days alone exists to protect against a flaky NAS probe and says
      # nothing about whether the fresh copy elsewhere actually succeeded.
      def ready?(pending)
        return true unless pending.reassigned?

        current = @manifest.folder(pending.folder_path)
        !current.nil? && current.drive_serial != pending.drive_serial && current.last_sync_status == 'ok'
      end

      def purge_one(pending, by_serial, result, dry_run:)
        drive = by_serial[pending.drive_serial]
        unless drive
          result.skipped << [pending, 'drive not mounted']
          return
        end

        base = File.join(drive.mount_point, pending.folder_path)
        dest = pending.whole_folder? ? base : File.join(base, pending.relative_path)
        unless inside?(dest, base) && File.expand_path(base).start_with?("#{File.expand_path(drive.mount_point)}/")
          result.skipped << [pending, 'path escapes its folder']
          return
        end

        label = pending.whole_folder? ? "#{pending.folder_path} (whole folder)" : "#{pending.folder_path}/#{pending.relative_path}"
        if dry_run
          @out.puts "  would delete #{label} from #{drive.friendly_name}"
          result.would_purge << [pending, drive.friendly_name]
          return
        end

        @out.puts "  deleting #{label} from #{drive.friendly_name}"
        return if yield(dest, drive) == false

        @manifest.record_deletion(pending, drive_serial: drive.serial_number)
        result.purged << [pending, drive.friendly_name]
      end

      def inside?(path, base)
        expanded = File.expand_path(path)
        expanded == File.expand_path(base) || expanded.start_with?("#{File.expand_path(base)}/")
      end
    end
  end
end
