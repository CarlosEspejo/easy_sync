# frozen_string_literal: true

require 'time'

module EasySync
  module Jbod
    # One manual sync run: discover folders on the NAS shares, place new ones,
    # mirror every folder to its assigned drive, then regenerate the dashboard.
    class Runner
      class SourceUnavailable < Error; end

      # A configured NAS share. +split+ means each subfolder is placed on its
      # own; otherwise the whole share is one unit.
      Source = Struct.new(:path, :split, keyword_init: true) do
        def name = File.basename(path)

        def self.from_config(entry)
          entry.is_a?(Hash) ? new(path: entry[:path], split: entry.fetch(:split, false)) : new(path: entry.to_s, split: false)
        end
      end

      # A folder as seen on the NAS. +key+ is its manifest folder_path
      # ("photos" for a whole share, "tv/Show Name" for a split one).
      SourceFolder = Struct.new(:key, :path, keyword_init: true)

      Report = Struct.new(:placed, :synced, :failed, :drive_full, :skipped, :unplaced, :missing_on_source, :warnings,
                          :purged, :would_purge, :pending, :loose_files, keyword_init: true) do
        def initialize(**)
          super
          (members - [:pending]).each { |m| self[m] ||= [] }
          self.pending ||= 0
        end
      end

      attr_reader :settings, :manifest

      # +settings+ is Config#jbod. +sizer+ returns the byte size of a source folder.
      def initialize(settings, manifest:, volume_info: nil, mirror: nil, dashboard: nil, purger: nil,
                     shell: Shell.new, out: $stdout, clock: Time, sizer: nil, dry_run: false, purge: nil)
        @settings = settings
        @manifest = manifest
        @shell = shell
        @out = out
        @clock = clock
        @dry_run = dry_run
        @purge = purge.nil? ? settings.fetch(:purge, true) : purge
        @volume_info = volume_info || VolumeInfo.new(mount_root: settings[:mount_root], shell: shell)
        @mirror = mirror || Mirror.new(shell: shell, extra_args: settings.fetch(:rsync_args, []) + (dry_run ? ['--dry-run'] : []))
        @dashboard = dashboard || Dashboard.new(manifest, warn_threshold: settings[:warn_threshold],
                                                          grace_days: settings[:grace_days], clock: clock)
        @purger = purger || Purger.new(manifest, grace_days: settings[:grace_days], grace_runs: settings[:grace_runs],
                                                 clock: clock, out: out)
        @sizer = sizer || method(:du_bytes)
      end

      def sources
        Array(settings[:sources]).map { |e| Source.from_config(e) }
      end

      def run
        report = Report.new
        folders, available = source_folders(report)
        mounted = refresh_drives(report)
        by_serial = mounted.to_h { |m| [m.serial_number, m] }
        # Free space as placements are made during this run, so two new folders
        # are not both sent to the drive that was emptiest at the start.
        free_ledger = mounted.to_h { |m| [m.serial_number, m.free_bytes] }
        new_folders = folders.count { |f| manifest.folder(f.key).nil? }
        @measured = 0
        if new_folders.positive?
          @out.puts "#{new_folders} new folder#{'s' if new_folders != 1} to measure and place " \
                    '(du over the network can take a while per folder)'
        end

        folders.each do |folder|
          record = manifest.folder(folder.key)
          if record.nil?
            target = place(folder, mounted, free_ledger, report) or next
          else
            target = by_serial[record.drive_serial]
            if target.nil?
              drive = manifest.drive(record.drive_serial)
              warn(report, "#{folder.key}: its drive #{drive&.friendly_name || record.drive_serial} is not mounted, skipping")
              manifest.mark_folder_status(folder.key, 'skipped_unmounted')
              report.skipped << folder.key
              next
            end
          end
          sync_folder(folder, target, report)
        end

        source_status = reconcile_manifest(folders, available, report)
        purge(mounted, report)

        mounted = refresh_drives(report, quiet: true)
        path = @dashboard.write(settings[:dashboard_path], mounted: mounted, source_status: source_status,
                                                            loose_files: report.loose_files)
        @out.puts "\nDashboard written to #{path}"
        summarize(report)
        report
      end

      # Folders found across the configured shares, plus the names of the shares
      # that were actually available. A share whose mount point is missing or
      # empty (a stale mount point left behind by macOS looks exactly like that)
      # is treated as unavailable so a --delete mirror never runs against it.
      def source_folders(report = Report.new)
        raise SourceUnavailable, 'no sources configured (set :jbod: :sources: in the config)' if sources.empty?

        folders = []
        available = []
        sources.each do |source|
          unless Dir.exist?(source.path) && !Dir.empty?(source.path)
            warn(report, "source #{source.path} is not mounted (or is empty), skipping")
            next
          end
          available << source.name
          if source.split
            subfolders(source.path).each do |name|
              folders << SourceFolder.new(key: File.join(source.name, name), path: File.join(source.path, name))
            end
            loose = loose_files(source.path)
            unless loose.empty?
              report.loose_files.concat(loose.map { |f| File.join(source.name, f) })
              warn(report, "#{source.path} has #{loose.size} loose file#{'s' if loose.size != 1} at the top level that " \
                           "will NOT be backed up (only folders are placed): #{loose.first(5).join(', ')}" \
                           "#{', ...' if loose.size > 5}. Move them into a folder on the NAS.")
            end
          else
            folders << SourceFolder.new(key: source.name, path: source.path)
          end
        end
        raise SourceUnavailable, 'none of the configured sources are mounted' if available.empty?

        [folders, available]
      end

      private

      def loose_files(path)
        excluded = Array(settings[:exclude_folders])
        Dir.children(path).sort.select { |n| File.file?(File.join(path, n)) && !excluded.include?(n) && !n.start_with?('.') }
      end

      def subfolders(path)
        excluded = Array(settings[:exclude_folders])
        Dir.children(path).sort.select do |n|
          File.directory?(File.join(path, n)) && !excluded.include?(n) && !n.start_with?('.')
        end
      end

      def refresh_drives(report, quiet: false)
        mounted = @volume_info.mounted_drives(manifest.drives)
        mounted.each do |m|
          manifest.update_drive_usage(m.serial_number, used_bytes: m.used_bytes, free_bytes: m.free_bytes,
                                                       capacity_bytes: m.capacity_bytes)
          if m.mount_point != File.join(settings[:mount_root], m.friendly_name) && !quiet
            warn(report, "#{m.friendly_name} is mounted at #{m.mount_point} (matched by serial, not by name)")
          end
        end
        unless quiet
          mounted_serials = mounted.map(&:serial_number)
          manifest.drives.reject { |d| mounted_serials.include?(d.serial_number) }.each do |d|
            warn(report, unmounted_message(d))
          end
        end
        mounted
      end

      # Best-effort: says *why* a drive isn't mounted when it's detectably a
      # locked FileVault volume rather than just absent, so "not mounted" isn't
      # the only signal you get when you forgot to unlock a drive.
      def unmounted_message(drive)
        base = "drive #{drive.friendly_name} (#{drive.serial_number}) is not mounted"
        case @volume_info.locked?(drive.friendly_name)
        when true then "#{base}: it's connected but still locked. Unlock it in Finder or with " \
                       "`diskutil apfs unlockVolume #{drive.friendly_name}` and sync again."
        else base
        end
      end

      def place(folder, mounted, free_ledger, report)
        @measured += 1
        @out.puts "  measuring #{folder.key} (new folder #{@measured})..."
        size = @sizer.call(folder.path)
        candidates = mounted.map { |m| m.dup.tap { |c| c.free_bytes = free_ledger[c.serial_number] } }
        target = Placement.choose(candidates, size_bytes: size)
        manifest.assign_folder(folder.key, target.serial_number, size_bytes: size,
                                                                 note: "new folder, most free space (#{Placement.format_bytes(target.free_bytes)})")
        @out.puts "Placing new folder #{folder.key} (#{Placement.format_bytes(size)}) on #{target.friendly_name}"
        report.placed << [folder.key, target.friendly_name]
        free_ledger[target.serial_number] -= size.to_i
        mounted.find { |m| m.serial_number == target.serial_number }
      rescue Placement::NoMountedDrives, Placement::DoesNotFit => e
        warn(report, "cannot place #{folder.key}: #{e.message}")
        report.unplaced << folder.key
        nil
      end

      def sync_folder(folder, target, report)
        destination = File.join(target.mount_point, folder.key)
        @out.puts "\n------------------ #{folder.key} -> #{target.friendly_name} ------------------"
        started = @clock.now.utc.iso8601
        result = @mirror.sync(folder.path, destination)
        manifest.record_sync(folder_path: folder.key, drive_serial: target.serial_number, started_at: started,
                             finished_at: @clock.now.utc.iso8601, exit_status: result.exit_status,
                             bytes_transferred: result.bytes_transferred, total_size_bytes: result.total_size_bytes)
        if result.success?
          report.synced << folder.key
          note_missing(folder, result.extraneous || [])
        elsif result.disk_full?
          manifest.mark_folder_status(folder.key, 'drive_full')
          warn(report, "#{folder.key} did not fully sync: #{target.friendly_name} is full " \
                       "(#{Placement.format_bytes(target.free_bytes)} free before this run). " \
                       "Move it to a drive with more room with `jbod reassign`.")
          report.drive_full << folder.key
        else
          warn(report, "rsync for #{folder.key} exited with status #{result.exit_status}")
          report.failed << folder.key
        end
      end

      # Flags manifest folders that were not seen this run. A folder whose share
      # was not mounted is only "unavailable", not missing.
      def reconcile_manifest(folders, available, report)
        status = folders.to_h { |f| [f.key, :present] }
        manifest.folders.each do |f|
          next if status.key?(f.folder_path)

          share = f.folder_path.split('/').first
          if available.include?(share)
            status[f.folder_path] = :missing
            report.missing_on_source << f.folder_path
            manifest.reconcile_pending(f.folder_path, [['', 'folder']]) unless @dry_run
            warn(report, "#{f.folder_path} is in the manifest but no longer on the NAS (still on #{drive_name(f.drive_serial)}); " \
                         "it will be deleted from the drive #{settings[:grace_days]} days after it first went missing")
          else
            status[f.folder_path] = :source_unavailable
            manifest.mark_folder_status(f.folder_path, 'skipped_source_unmounted')
            report.skipped << f.folder_path
          end
        end
        status
      end

      # Feeds rsync's "would delete" report into the pending_deletions table.
      def note_missing(folder, extraneous)
        return if @dry_run

        counts = manifest.reconcile_pending(folder.key, extraneous)
        return if counts.values.all?(&:zero?)

        @out.puts "  #{folder.key}: #{counts[:new]} newly missing on NAS, #{counts[:still]} still missing, " \
                  "#{counts[:reappeared]} reappeared"
      end

      def purge(mounted, report)
        report.pending = manifest.pending_deletions.size
        return unless @purge

        expired = manifest.expired_deletions(now: @clock.now, grace_days: settings[:grace_days],
                                             grace_runs: settings[:grace_runs])
        return if expired.empty?

        @out.puts "\n------------------ purging #{expired.size} expired deletion#{'s' if expired.size != 1} ------------------"
        result = @purger.run(mounted, dry_run: @dry_run)
        report.purged = result.purged.map { |p, drive| [p.folder_path, p.relative_path, drive] }
        report.would_purge = result.would_purge.map { |p, drive| [p.folder_path, p.relative_path, drive] }
        result.skipped.each { |p, why| warn(report, "not purging #{p.folder_path}/#{p.relative_path}: #{why}") }
      end

      def du_bytes(path)
        result = @shell.capture(['du', '-sk', path])
        raise Error, "du failed for #{path}: #{result.output}" unless result.success?

        Integer(result.output.split.first) * 1024
      end

      def drive_name(serial)
        manifest.drive(serial)&.friendly_name || serial
      end

      def warn(report, message)
        report.warnings << message
        @out.puts "WARNING: #{message}"
      end

      def summarize(report)
        @out.puts "Synced #{report.synced.size}, placed #{report.placed.size} new, failed #{report.failed.size}, " \
                  "drive full #{report.drive_full.size}, skipped #{report.skipped.size}, " \
                  "unplaced #{report.unplaced.size}, purged #{report.purged.size}, " \
                  "#{report.pending.to_i} pending deletion#{'s' if report.pending.to_i != 1}, warnings #{report.warnings.size}"
      end
    end
  end
end
