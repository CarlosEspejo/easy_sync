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
      # 'degraded_stable' (nonzero reallocated sectors that haven't grown since
      # the last verified checkpoint) gets its own :stable level, distinct from
      # :warning, so old non-progressing wear doesn't read as an active failure.
      HEALTH_LEVELS = { 'ok' => :ok, 'degraded_stable' => :stable, 'warning' => :warning, 'failing' => :critical }.freeze

      attr_reader :manifest, :grace_days

      def initialize(manifest, grace_days: 7, scrub_stale_days: 30, clock: Time)
        @manifest = manifest
        @grace_days = grace_days
        @scrub_stale_days = scrub_stale_days
        @clock = clock
      end

      # +mounted+ is the list of MountedDrive structs from the current run;
      # drives not in it are rendered with their last known numbers.
      # +source_status+ maps folder_path => :present | :missing for folders seen on the NAS.
      # +running+ is the RunLock::Status of whatever holds the run lock (sync,
      # scrub, clean, or restore all share it), or nil when nothing is
      # running. An ETA is only estimated for a real sync; the others just
      # say how long they've been going (see #other_running_line).
      def render(mounted: [], source_status: {}, loose_files: [], running: nil)
        @running = running
        by_serial = mounted.to_h { |m| [m.serial_number, m] }
        drives = manifest.drives.map { |d| drive_view(d, by_serial[d.serial_number]) }
        locals = {
          drives: drives,
          folders: manifest.folders,
          names: manifest.drives(include_retired: true).to_h { |d| [d.serial_number, d.retired? ? "#{d.friendly_name} (retired)" : d.friendly_name] },
          history: manifest.history(limit: 50),
          runs: manifest.sync_runs(limit: 30),
          generated_at: @clock.now,
          total_capacity_bytes: drives.sum { |d| d.capacity_bytes.to_i },
          total_free_bytes: drives.sum { |d| d.free_bytes.to_i },
          warnings: drives.select { |d| %i[warning critical].include?(d.level) },
          source_status: source_status,
          loose_files: loose_files,
          pending: manifest.pending_deletions,
          inventory: manifest.source_inventory,
          deletions: manifest.deletions(limit: 30),
          scrub_findings: manifest.scrub_findings,
          running: running,
          eta: running&.kind == 'sync' ? SyncEta.for(manifest, running.started_at) : nil
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

      HEALTH_LABELS = { 'ok' => 'SMART ok', 'degraded_stable' => 'SMART: historical wear, stable',
                        'warning' => 'SMART: starting to fail', 'failing' => 'SMART: FAILING',
                        'unknown' => 'SMART n/a' }.freeze

      def health_label(status) = HEALTH_LABELS.fetch(status, 'SMART n/a')

      # A healthy tile shows only its temperature; the sector counters matter
      # only once something is wrong (they stay in the tooltip otherwise).
      def health_line(view)
        temp = view.drive.smart_detail.to_s[/\d+°C/] if view.health == 'ok'
        [health_label(view.health), temp].compact.join(' · ')
      end

      def health_detail_shown?(view) = %w[degraded_stable warning failing].include?(view.health) && view.drive.smart_detail

      # Renders a SyncEta::Estimate the same way `status` phrases it, for the
      # banner shown while a sync is running. nil (nothing running, or
      # nothing left to estimate) means the caller shows nothing at all.
      def eta_line(eta)
        case eta&.status
        when nil then nil
        when :waiting_for_first_folder
          'Estimating time remaining: still measuring/placing folders, or waiting on a large first copy to finish...'
        when :waiting_for_first_transfer
          "#{eta.never_synced_count} folder#{'s' if eta.never_synced_count != 1} never synced (#{bytes(eta.never_synced_bytes)}); " \
            'still waiting for one to finish before estimating their time.'
        when :estimate
          "About #{Placement.format_duration(eta.seconds)} remaining (#{eta.never_synced_count} folder#{'s' if eta.never_synced_count != 1} never synced, " \
            "#{eta.to_reverify} to re-verify) - rough estimate, NAS/network speed varies."
        end
      end

      # For scrub/clean/restore holding the shared lock: none of those have a
      # sync-style ETA, so just say how long the run has been going.
      def other_running_line(running)
        "#{running.kind.capitalize} in progress (started #{Placement.format_duration(@clock.now - running.started_at)} ago)."
      end

      # The mount path is only news when macOS mounted the drive somewhere
      # other than under its own name (e.g. "backup-02-6tb 1").
      def unexpected_mount?(view) = view.mounted && File.basename(view.mount_point) != view.drive.friendly_name

      MODEL_SHOWN = 20   # branded_model past this wraps the tile onto two lines

      # [text to show, full string for a title attribute (nil when nothing
      # was cut, so no tooltip appears for text that's already complete)].
      def serial_line(drive)
        model = drive.branded_model
        return [drive.serial_number, nil] unless model

        full = "#{drive.serial_number} · #{model}"
        return [full, nil] if model.length <= MODEL_SHOWN

        ["#{drive.serial_number} · #{model[0, MODEL_SHOWN - 1].rstrip}…", full]
      end

      # Inventory rows for one share, by state.
      def inventory_for(inventory, share)
        rows = inventory.select { |e| e.share == share }
        { total: rows.size, placed: rows.count { |e| e.state == 'placed' },
          unplaced: rows.select { |e| e.state == 'unplaced' }, empty: rows.count { |e| e.state == 'empty' },
          total_bytes: rows.sum { |e| e.size_bytes.to_i } }
      end

      # -- template helpers ------------------------------------------------

      def bytes(value) = Placement.format_bytes(value)

      def percent(fraction)
        fraction.nil? ? '—' : format('%.0f%%', fraction * 100)
      end

      def when_(iso)
        return 'never' if iso.nil? || iso.empty?

        #   (non-breaking space) between date and time: a table column
        # narrower than the full string must not split it across two lines.
        Time.parse(iso).localtime.strftime("%Y-%m-%d %H:%M")
      rescue ArgumentError
        iso
      end

      def h(text) = ERB::Util.html_escape(text.to_s)

      # Groups folders by share (the first path segment): a whole-share source
      # like "photos" is its own group of one; a split share like "tv" groups
      # every "tv/<show>". Returns [[share, [folders...]], ...] in share order.
      # +inventory+ adds shares that have nothing placed yet (nothing fit), so
      # they still get a summary line.
      def by_share(folders, inventory = [])
        groups = folders.group_by { |f| f.folder_path.split('/').first }
        inventory.each { |e| groups[e.share] ||= [] }
        groups.sort_by(&:first)
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

      # 'never' means assigned but not yet copied (mid-run, or an interrupted
      # run): pending work, not a problem, so it never lands in Needs attention.
      NEUTRAL = %w[ok never].freeze

      def problems_in(folders, source_status)
        folders.count { |f| !NEUTRAL.include?(folder_status(f, source_status)) }
      end

      def unsynced_in(folders, source_status)
        folders.count { |f| folder_status(f, source_status) == 'never' }
      end

      # The folder table body, shared by the "needs attention" list and each
      # per-share group. Rows needing attention sort first within a group.
      def folder_rows(folders, source_status, pending, names)
        rows = folders.sort_by { |f| [NEUTRAL.include?(folder_status(f, source_status)) ? 1 : 0, f.folder_path] }.map do |f|
          status = folder_status(f, source_status)
          whole = pending.find { |p| p.whole_folder? && p.folder_path == f.folder_path }
          note = whole ? %(<br><small style="color:var(--muted)">deleted from drive after #{expiry(whole)}</small>) : ''
          "<tr><td>#{h f.folder_path}</td><td class=\"drive\">#{h names.fetch(f.drive_serial, f.drive_serial)}</td>" \
            "<td class=\"num\">#{bytes(f.size_bytes)}</td><td>#{when_(f.last_synced_at)}</td>" \
            "<td><span class=\"status #{status}\">#{h status_label(status)}</span>#{note}</td>" \
            "<td>#{when_(f.assigned_at)}</td></tr>"
        end
        '<table><thead><tr><th>Folder</th><th>Drive</th><th class="num">Size</th><th>Last synced</th>' \
          "<th>Status</th><th>Assigned</th></tr></thead><tbody>#{rows.join}</tbody></table>"
      end

      # A 'reassigned' row also needs its folder verified synced to its new
      # drive before it's actually eligible (see Purger#ready?); the date
      # alone is only the earliest it could happen.
      def expiry(pending)
        date = pending.expires_at(grace_days).localtime.strftime('%Y-%m-%d')
        return date unless pending.reassigned?

        manifest.folder(pending.folder_path)&.last_sync_status == 'ok' ? date : "#{date} (once resynced)"
      end

      def pending_label(p)
        p.whole_folder? ? "#{p.folder_path} (whole folder)" : "#{p.folder_path}/#{p.relative_path}"
      end

      def pending_kind(p, names)
        p.reassigned? ? "moved off #{names.fetch(p.drive_serial, p.drive_serial)}" : p.kind
      end

      # "scrubbing now", "scrubbed N days ago", or "never scrubbed", shown on
      # every drive tile regardless of whether it's overdue.
      def scrub_status_line(view)
        return 'scrubbing now' if scrubbing?(view)

        through = manifest.scrubbed_through(view.drive.serial_number)
        through ? "scrubbed #{days_ago(through)} days ago" : 'never scrubbed'
      end

      # True while a running `scrub` (RunLock#kind) is currently on this
      # drive - set via RunLock#note as scrub works through its targets.
      def scrubbing?(view) = @running&.kind == 'scrub' && Array(@running.current).include?(view.drive.friendly_name)

      # Same overdue rule as `status`: something has to have actually synced
      # to the drive first, so a brand-new empty drive is never overdue.
      def scrub_overdue?(view)
        return false unless view.folders.any?(&:last_synced_at)

        through = manifest.scrubbed_through(view.drive.serial_number)
        through.nil? || Time.parse(through) < (@clock.now - (@scrub_stale_days * 86_400))
      end

      def days_ago(iso)
        ((@clock.now - Time.parse(iso)) / 86_400).floor
      end

      def scrub_finding_phrase(row)
        return 'unresolved: compare with the NAS copy' if row.status == 'unresolved'
        return 'refetched, awaiting re-check' if row.refetched_at

        'awaiting refetch'
      end
    end
  end
end
