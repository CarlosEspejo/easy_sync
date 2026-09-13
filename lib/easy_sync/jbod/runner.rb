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

      Report = Struct.new(:placed, :synced, :failed, :skipped, :unplaced, :missing_on_source, :warnings,
                          keyword_init: true) do
        def initialize(**)
          super
          members.each { |m| self[m] ||= [] }
        end
      end

      attr_reader :settings, :manifest

      # +settings+ is Config#jbod. +sizer+ returns the byte size of a source folder.
      def initialize(settings, manifest:, volume_info: nil, mirror: nil, dashboard: nil,
                     shell: Shell.new, out: $stdout, clock: Time, sizer: nil)
        @settings = settings
        @manifest = manifest
        @shell = shell
        @out = out
        @clock = clock
        @volume_info = volume_info || VolumeInfo.new(mount_root: settings[:mount_root], shell: shell)
        @mirror = mirror || Mirror.new(shell: shell, delete: settings.fetch(:delete, true),
                                       extra_args: settings.fetch(:rsync_args, []))
        @dashboard = dashboard || Dashboard.new(manifest, warn_threshold: settings[:warn_threshold], clock: clock)
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

        mounted = refresh_drives(report, quiet: true)
        path = @dashboard.write(settings[:dashboard_path], mounted: mounted, source_status: source_status)
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
          else
            folders << SourceFolder.new(key: source.name, path: source.path)
          end
        end
        raise SourceUnavailable, 'none of the configured sources are mounted' if available.empty?

        [folders, available]
      end

      private

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
            warn(report, "drive #{d.friendly_name} (#{d.serial_number}) is not mounted")
          end
        end
        mounted
      end

      def place(folder, mounted, free_ledger, report)
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
            warn(report, "#{f.folder_path} is in the manifest but no longer on the NAS (still on #{drive_name(f.drive_serial)})")
          else
            status[f.folder_path] = :source_unavailable
            manifest.mark_folder_status(f.folder_path, 'skipped_source_unmounted')
            report.skipped << f.folder_path
          end
        end
        status
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
                  "skipped #{report.skipped.size}, unplaced #{report.unplaced.size}, warnings #{report.warnings.size}"
      end
    end
  end
end
