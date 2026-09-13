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
                             :used_fraction, :level, :health, :folders, keyword_init: true)

      # Tile colour comes from SMART health only. Fullness is shown as a number;
      # a JBOD drive at 97% is healthy by design and must not look like a problem.
      HEALTH_LEVELS = { 'ok' => :ok, 'warning' => :warning, 'failing' => :critical }.freeze

      attr_reader :manifest, :grace_days

      def initialize(manifest, grace_days: 7, clock: Time)
        @manifest = manifest
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
          names: manifest.drives(include_retired: true).to_h { |d| [d.serial_number, d.retired? ? "#{d.friendly_name} (retired)" : d.friendly_name] },
          history: manifest.history(limit: 50),
          runs: manifest.sync_runs(limit: 30),
          generated_at: @clock.now,
          warnings: drives.select { |d| %i[warning critical].include?(d.level) },
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
                      used_fraction: fraction, level: HEALTH_LEVELS.fetch(drive.smart_status, :unknown),
                      health: drive.smart_status || 'unknown',
                      folders: manifest.folders_on(drive.serial_number))
      end

      HEALTH_LABELS = { 'ok' => 'SMART ok', 'warning' => 'SMART: starting to fail', 'failing' => 'SMART: FAILING',
                        'unknown' => 'SMART n/a' }.freeze

      def health_label(status) = HEALTH_LABELS.fetch(status, 'SMART n/a')

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

      # Groups folders by share (the first path segment): a whole-share source
      # like "photos" is its own group of one; a split share like "tv" groups
      # every "tv/<show>". Returns [[share, [folders...]], ...] in share order.
      def by_share(folders)
        folders.group_by { |f| f.folder_path.split('/').first }.sort_by(&:first)
      end

      def total_size(folders) = folders.sum { |f| f.size_bytes.to_i }

      # Status label for a folder row, resolving the source-side state first.
      def folder_status(folder, source_status)
        case source_status[folder.folder_path]
        when :missing then 'missing'
        when :source_unavailable then 'skipped_source_unmounted'
        else folder.last_sync_status || 'never'
        end
      end

      STATUS_LABELS = {
        'missing' => 'missing on NAS', 'skipped_source_unmounted' => 'share not mounted',
        'skipped_unmounted' => 'drive not mounted', 'drive_full' => 'drive full'
      }.freeze

      def status_label(status) = STATUS_LABELS.fetch(status, status)

      def problems_in(folders, source_status)
        folders.count { |f| folder_status(f, source_status) != 'ok' }
      end

      # The folder table body, shared by the "needs attention" list and each
      # per-share group. Rows needing attention sort first within a group.
      def folder_rows(folders, source_status, pending, names)
        rows = folders.sort_by { |f| [folder_status(f, source_status) == 'ok' ? 1 : 0, f.folder_path] }.map do |f|
          status = folder_status(f, source_status)
          whole = pending.find { |p| p.whole_folder? && p.folder_path == f.folder_path }
          note = whole ? %(<br><small style="color:var(--muted)">deleted from drive after #{expiry(whole)}</small>) : ''
          "<tr><td>#{h f.folder_path}</td><td>#{h names.fetch(f.drive_serial, f.drive_serial)}</td>" \
            "<td class=\"num\">#{bytes(f.size_bytes)}</td><td>#{when_(f.last_synced_at)}</td>" \
            "<td><span class=\"status #{status}\">#{h status_label(status)}</span>#{note}</td>" \
            "<td>#{when_(f.assigned_at)}</td></tr>"
        end
        '<table><thead><tr><th>Folder</th><th>Drive</th><th class="num">Size</th><th>Last synced</th>' \
          "<th>Status</th><th>Assigned</th></tr></thead><tbody>#{rows.join}</tbody></table>"
      end

      def expiry(pending)
        pending.expires_at(grace_days).localtime.strftime('%Y-%m-%d')
      end

      def pending_label(p)
        p.whole_folder? ? "#{p.folder_path} (whole folder)" : "#{p.folder_path}/#{p.relative_path}"
      end
    end
  end
end
