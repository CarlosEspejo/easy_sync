# frozen_string_literal: true

require 'time'

module EasySync
  module Jbod
    # One manual sync run: discover folders on the NAS, place new ones, mirror
    # every folder to its assigned drive, then regenerate the dashboard.
    class Runner
      class SourceUnavailable < Error; end

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

      def run
        report = Report.new
        folders = source_folders
        mounted = refresh_drives(report)
        by_serial = mounted.to_h { |m| [m.serial_number, m] }
        # Free space as placements are made during this run, so two new folders
        # are not both sent to the drive that was emptiest at the start.
        free_ledger = mounted.to_h { |m| [m.serial_number, m.free_bytes] }

        folders.each do |name|
          record = manifest.folder(name)
          if record.nil?
            target = place(name, mounted, free_ledger, report) or next
          else
            target = by_serial[record.drive_serial]
            if target.nil?
              drive = manifest.drive(record.drive_serial)
              warn(report, "#{name}: its drive #{drive&.friendly_name || record.drive_serial} is not mounted, skipping")
              manifest.mark_folder_status(name, 'skipped_unmounted')
              report.skipped << name
              next
            end
          end
          sync_folder(name, target, report)
        end

        source_status = folders.to_h { |f| [f, :present] }
        manifest.folders.each do |f|
          next if source_status.key?(f.folder_path)

          source_status[f.folder_path] = :missing
          report.missing_on_source << f.folder_path
          warn(report, "#{f.folder_path} is in the manifest but no longer on the NAS (still on #{drive_name(f.drive_serial)})")
        end

        mounted = refresh_drives(report, quiet: true)
        path = @dashboard.write(settings[:dashboard_path], mounted: mounted, source_status: source_status)
        @out.puts "\nDashboard written to #{path}"
        summarize(report)
        report
      end

      # Top-level directories under the source root, excluding configured names.
      def source_folders
        root = settings[:source_root]
        raise SourceUnavailable, "source root #{root} is not mounted" unless Dir.exist?(root)

        excluded = Array(settings[:exclude_folders])
        names = Dir.children(root).sort.select do |n|
          File.directory?(File.join(root, n)) && !excluded.include?(n) && !n.start_with?('.')
        end
        raise SourceUnavailable, "source root #{root} contains no folders; refusing to run a --delete mirror" if names.empty?

        names
      end

      private

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

      def place(name, mounted, free_ledger, report)
        size = @sizer.call(File.join(settings[:source_root], name))
        candidates = mounted.map { |m| m.dup.tap { |c| c.free_bytes = free_ledger[c.serial_number] } }
        target = Placement.choose(candidates, size_bytes: size)
        manifest.assign_folder(name, target.serial_number, size_bytes: size,
                                                           note: "new folder, most free space (#{Placement.format_bytes(target.free_bytes)})")
        @out.puts "Placing new folder #{name} (#{Placement.format_bytes(size)}) on #{target.friendly_name}"
        report.placed << [name, target.friendly_name]
        free_ledger[target.serial_number] -= size.to_i
        mounted.find { |m| m.serial_number == target.serial_number }
      rescue Placement::NoMountedDrives, Placement::DoesNotFit => e
        warn(report, "cannot place #{name}: #{e.message}")
        report.unplaced << name
        nil
      end

      def sync_folder(name, target, report)
        source = File.join(settings[:source_root], name)
        destination = File.join(target.mount_point, name)
        @out.puts "\n------------------ #{name} -> #{target.friendly_name} ------------------"
        started = @clock.now.utc.iso8601
        result = @mirror.sync(source, destination)
        manifest.record_sync(folder_path: name, drive_serial: target.serial_number, started_at: started,
                             finished_at: @clock.now.utc.iso8601, exit_status: result.exit_status,
                             bytes_transferred: result.bytes_transferred, total_size_bytes: result.total_size_bytes)
        if result.success?
          report.synced << name
        else
          warn(report, "rsync for #{name} exited with status #{result.exit_status}")
          report.failed << name
        end
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
