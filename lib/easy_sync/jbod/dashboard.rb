# frozen_string_literal: true

require 'erb'
require 'fileutils'
require 'time'

module EasySync
  module Jbod
    # Renders the static HTML status report from the manifest.
    class Dashboard
      TEMPLATE = File.expand_path('../templates/dashboard.html.erb', __dir__)

      DriveView = Struct.new(:drive, :mounted, :mount_point, :capacity_bytes, :used_bytes, :free_bytes,
                             :used_fraction, :level, :folders, keyword_init: true)

      attr_reader :manifest, :warn_threshold, :grace_days

      def initialize(manifest, warn_threshold: 0.85, grace_days: 7, clock: Time)
        @manifest = manifest
        @warn_threshold = warn_threshold
        @grace_days = grace_days
        @clock = clock
      end

      # +mounted+ is the list of MountedDrive structs from the current run;
      # drives not in it are rendered with their last known numbers.
      # +source_status+ maps folder_path => :present | :missing for folders seen on the NAS.
      def render(mounted: [], source_status: {}, loose_files: [])
        by_serial = mounted.to_h { |m| [m.serial_number, m] }
        drives = manifest.drives.map { |d| drive_view(d, by_serial[d.serial_number]) }
        locals = {
          drives: drives,
          folders: manifest.folders,
          names: manifest.drives.to_h { |d| [d.serial_number, d.friendly_name] },
          history: manifest.history(limit: 50),
          runs: manifest.sync_runs(limit: 30),
          generated_at: @clock.now,
          warnings: drives.select { |d| d.level != :ok },
          source_status: source_status,
          loose_files: loose_files,
          pending: manifest.pending_deletions,
          deletions: manifest.deletions(limit: 30)
        }
        scope = binding
        locals.each { |name, value| scope.local_variable_set(name, value) }
        ERB.new(File.read(TEMPLATE, encoding: 'UTF-8'), trim_mode: '-').result(scope)
      end

      def write(path, **)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, render(**))
        path
      end

      def drive_view(drive, mounted)
        capacity = mounted ? mounted.capacity_bytes : drive.capacity_bytes
        used = mounted ? mounted.used_bytes : drive.last_used_bytes
        free = mounted ? mounted.free_bytes : drive.last_free_bytes
        fraction = used && capacity.to_i.positive? ? used.to_f / capacity : nil
        DriveView.new(drive: drive, mounted: !mounted.nil?, mount_point: mounted&.mount_point,
                      capacity_bytes: capacity, used_bytes: used, free_bytes: free,
                      used_fraction: fraction, level: level_for(fraction),
                      folders: manifest.folders_on(drive.serial_number))
      end

      def level_for(fraction)
        return :unknown if fraction.nil?
        return :critical if fraction >= 0.95
        return :warning if fraction >= warn_threshold

        :ok
      end

      # -- template helpers ------------------------------------------------

      def bytes(value) = Placement.format_bytes(value)

      def percent(fraction)
        fraction.nil? ? '—' : format('%.0f%%', fraction * 100)
      end

      def when_(iso)
        return 'never' if iso.nil? || iso.empty?

        Time.parse(iso).localtime.strftime('%Y-%m-%d %H:%M')
      rescue ArgumentError
        iso
      end

      def h(text) = ERB::Util.html_escape(text.to_s)

      def expiry(pending)
        pending.expires_at(grace_days).localtime.strftime('%Y-%m-%d')
      end

      def pending_label(p)
        p.whole_folder? ? "#{p.folder_path} (whole folder)" : "#{p.folder_path}/#{p.relative_path}"
      end
    end
  end
end
