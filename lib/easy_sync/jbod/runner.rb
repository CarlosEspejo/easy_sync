# frozen_string_literal: true

require 'time'

module EasySync
  module Jbod
    # One manual sync run: discover folders on the NAS shares, place new ones,
    # mirror every folder to its assigned drive, then regenerate the dashboard.
    class Runner
      class SourceUnavailable < Error; end

      # A configured NAS share.
      Source = Struct.new(:path, keyword_init: true) do
        def name = File.basename(path)

        def self.from_config(entry)
          new(path: entry.is_a?(Hash) ? entry[:path] : entry.to_s)
        end
      end

      # A placement unit as seen on the NAS. +key+ is its manifest folder_path:
      # "tv/Show Name" for a subfolder, or the share name ("synology") for
      # either a share an earlier build placed whole or, with +root_only+, the
      # share's loose top-level files (see docs/fine-placement.md).
      SourceFolder = Struct.new(:key, :path, :root_only, keyword_init: true) do
        def share = key.split('/').first
      end

      Report = Struct.new(:placed, :synced, :failed, :drive_full, :skipped, :unplaced, :missing_on_source, :warnings,
                          :purged, :would_purge, :pending, :unhealthy, :empty, :refetched, keyword_init: true) do
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
        @mirror = mirror || Mirror.new(shell: shell, excludes: settings.fetch(:exclude_folders, []),
                                       extra_args: settings.fetch(:rsync_args, []) + (dry_run ? ['--dry-run'] : []))
        @dashboard = dashboard || Dashboard.new(manifest, grace_days: settings[:grace_days],
                                                          scrub_stale_days: settings.fetch(:scrub_stale_days, 30), clock: clock)
        @purger = purger || Purger.new(manifest, grace_days: settings[:grace_days], grace_runs: settings[:grace_runs],
                                                 clock: clock, out: out)
        @sizer = sizer || method(:du_bytes)
      end

      def sources
        Array(settings[:sources]).map { |e| Source.from_config(e) }
      end

      def run
        report = Report.new
        @run_started_at = @clock.now.utc.iso8601
        folders, available = source_folders(report)
        mounted = refresh_drives(report)
        copy_state_to_drives(mounted, report)   # at the start too, so an interrupted run still leaves a copy
        by_serial = mounted.to_h { |m| [m.serial_number, m] }
        # Free space as placements are made during this run, so two new folders
        # are not both sent to the drive that was emptiest at the start.
        # Seeded from whichever is smaller of live `df` free space and
        # (capacity minus what the manifest already promised that drive,
        # synced or not): a folder placed by an earlier run whose copy
        # phase hasn't reached this drive yet doesn't show up in `df`, so
        # trusting `df` alone lets a later run keep stacking new folders on
        # top of commitments it can't see. Found on the real fleet:
        # backup-06-8tb ended up promised 8.55 TB against a 7.28 TiB drive
        # this way, after an interrupted run's placements were invisible to
        # the next run's capacity check.
        free_ledger = mounted.to_h do |m|
          promised = manifest.folders_on(m.serial_number).sum { |f| f.size_bytes.to_i }
          committed_free = m.capacity_bytes.to_i - promised
          [m.serial_number, [m.free_bytes.to_i, committed_free].min]
        end
        new_folders = folders.count { |f| manifest.folder(f.key).nil? }
        @measured = 0
        @placed_this_run = Hash.new { |h, k| h[k] = [] }
        if new_folders.positive?
          @out.puts "#{new_folders} new folder#{'s' if new_folders != 1} to measure and place " \
                    '(du over the network can take a while per folder)'
        end

        # Phase 1: decide where everything goes, before any copying, so the
        # full picture (including what does NOT fit) exists even if the long
        # copy phase is interrupted.
        plan = []
        inventory = []
        folders.each do |folder|
          record = manifest.folder(folder.key)
          if record.nil?
            target, size, state, detail = place(folder, mounted, free_ledger, report)
            inventory << { folder_path: folder.key, size_bytes: size, state: state, detail: detail }
            plan << [folder, target] if target
          else
            inventory << { folder_path: folder.key, size_bytes: record.size_bytes, state: 'placed',
                           detail: "on #{drive_name(record.drive_serial)}" }
            target = by_serial[record.drive_serial]
            if target.nil?
              drive = manifest.drive(record.drive_serial)
              warn(report, "#{folder.key}: its drive #{drive&.friendly_name || record.drive_serial} is not mounted, skipping")
              manifest.mark_folder_status(folder.key, 'skipped_unmounted') unless @dry_run
              report.skipped << folder.key
              next
            end
            plan << [folder, target]
          end
        end
        manifest.replace_source_inventory(inventory) unless @dry_run
        unplaced_bytes = inventory.sum { |i| i[:state] == 'unplaced' ? i[:size_bytes].to_i : 0 }
        @out.puts "\nPlan: #{plan.size} folder#{'s' if plan.size != 1} to sync (#{report.placed.size} newly placed), " \
                  "#{report.unplaced.size} not backed up (#{Placement.format_bytes(unplaced_bytes)}: no room), " \
                  "#{report.empty.size} empty on the NAS"

        # Folders that vanished from a mounted share are flagged now, before
        # the copy phase, so an interrupted run still notices them.
        source_status = reconcile_manifest(folders, available, report)

        # Phase 2: copy. Deletions come last.
        plan.each { |folder, target| sync_folder(folder, target, report) }
        purge(mounted, report)

        if @dry_run
          @out.puts "\nDRY RUN: nothing was copied, recorded, or deleted, and the dashboard was left as it was."
        else
          mounted = refresh_drives(report, quiet: true)
          copy_state_to_drives(mounted, report)
          path = @dashboard.write(settings[:dashboard_path], mounted: mounted, source_status: source_status)
          @out.puts "\nDashboard written to #{path}"
        end
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
          folders.concat(units_of(source))
        end
        raise SourceUnavailable, 'none of the configured sources are mounted' if available.empty?

        [folders, available]
      end

      private

      # A share placed whole (a 'tree' row keyed by the share name) stays one
      # unit until `easy_sync split` converts it: placed folders never change
      # shape on their own. Every other share is one unit per top-level
      # subfolder, plus a root unit for its loose top-level files.
      def units_of(source)
        whole = manifest.folder(source.name)
        return [SourceFolder.new(key: source.name, path: source.path)] if whole && !whole.root?

        units = subfolders(source.path).map do |name|
          SourceFolder.new(key: File.join(source.name, name), path: File.join(source.path, name))
        end
        units << SourceFolder.new(key: source.name, path: source.path, root_only: true) if whole || loose_files(source.path).any?
        units
      end

      def loose_files(path) = ShareScan.loose_files(path, settings[:exclude_folders])
      def subfolders(path) = ShareScan.subfolders(path, settings[:exclude_folders])

      def refresh_drives(report, quiet: false)
        mounted = @volume_info.mounted_drives(manifest.drives)
        mounted.each do |m|
          unless @dry_run
            manifest.update_drive_usage(m.serial_number, used_bytes: m.used_bytes, free_bytes: m.free_bytes,
                                                         capacity_bytes: m.capacity_bytes)
            backfill_model(m) if m.drive.model.nil?
          end
          if m.mount_point != File.join(settings[:mount_root], m.friendly_name) && !quiet
            warn(report, "#{m.friendly_name} is mounted at #{m.mount_point} (matched by serial, not by name)")
          end
          check_health(m, report) unless quiet
        end
        unless quiet
          mounted_serials = mounted.map(&:serial_number)
          manifest.drives.reject { |d| mounted_serials.include?(d.serial_number) }.each do |d|
            warn(report, unmounted_message(d))
          end
        end
        mounted
      end

      # Drives registered before the model field existed (or whose enclosure
      # didn't expose smartctl at registration time) get it filled in here,
      # once per drive: after the first success the drive's model is no
      # longer nil, so this stops asking smartctl on every subsequent run.
      def backfill_model(mounted_drive)
        model = @volume_info.smartctl_model(mounted_drive.mount_point)
        manifest.update_drive_model(mounted_drive.serial_number, model: model) if model
      end

      # Reads SMART once per run for each mounted drive and records it. A
      # drive that is starting to fail is the one thing worth shouting about -
      # but only when a bad counter is actually growing. A reallocated-sector
      # count that's nonzero but unchanged since the last verified checkpoint
      # (or since it was first seen) is old, stable damage, not an active
      # failure in progress, and gets the quieter 'degraded_stable' status
      # instead of nagging on every run.
      def check_health(mounted_drive, report)
        health = @volume_info.smart_health(mounted_drive.mount_point) or return
        status = health.status
        unless @dry_run
          if health.reallocated_sector_ct
            manifest.record_smart_check(mounted_drive.serial_number, reallocated_sector_ct: health.reallocated_sector_ct)
          end
          status = resolve_alert_status(mounted_drive.serial_number, health)
          manifest.update_drive_health(mounted_drive.serial_number, status: status, detail: health.detail,
                                                                     power_on_hours: health.power_on_hours)
        end
        return if %w[ok unknown degraded_stable].include?(status)

        report.unhealthy << [mounted_drive.friendly_name, status]
        verb = status == 'failing' ? 'is FAILING' : 'is starting to fail'
        warn(report, "drive #{mounted_drive.friendly_name} #{verb}: SMART says #{health.detail}. " \
                     "Plan to replace it: register a new drive, then " \
                     "`easy_sync replace-drive #{mounted_drive.friendly_name} --to NEW_NAME --copy`.")
      end

      # Downgrades a 'warning' caused solely by a non-growing reallocated
      # count to 'degraded_stable'. Any other reason for 'warning' (pending
      # sectors, uncorrectable sectors, media errors, an NVMe critical flag)
      # is left alone regardless of reallocated-count trend.
      def resolve_alert_status(serial_number, health)
        return health.status unless health.status == 'warning' && !health.other_bad

        baseline = manifest.reallocated_baseline(serial_number)
        current = health.reallocated_sector_ct.to_i
        baseline && current > baseline ? 'warning' : 'degraded_stable'
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

      # Returns [target, size, state, detail]; target is nil when not placed.
      def place(folder, mounted, free_ledger, report)
        if folder.root_only ? loose_files(folder.path).empty? : empty_source?(folder.path)
          warn(report, "#{folder.key} has no files on the NAS (only excluded or hidden ones); not placing it")
          report.empty << folder.key
          return [nil, 0, 'empty', 'no real files on the NAS']
        end
        @measured += 1
        @out.puts "  measuring #{folder.key} (new folder #{@measured})..."
        size = folder.root_only ? loose_bytes(folder.path) : @sizer.call(folder.path)
        candidates = mounted.map { |m| m.dup.tap { |c| c.free_bytes = free_ledger[c.serial_number] } }
        prefer = share_drives(folder.share)
        target = Placement.choose(candidates, size_bytes: size, reserve_bytes: settings.fetch(:reserve_bytes, 0),
                                              prefer: prefer)
        why = prefer.include?(target.serial_number) ? "with the rest of #{folder.share}" : 'most free space'
        if @dry_run
          @out.puts "Would place new folder #{folder.key} (#{Placement.format_bytes(size)}) on #{target.friendly_name}"
        else
          manifest.assign_folder(folder.key, target.serial_number, size_bytes: size,
                                                                   scope: folder.root_only ? 'root' : 'tree',
                                                                   note: "new folder, #{why} (#{Placement.format_bytes(target.free_bytes)} free)")
          @out.puts "Placing new folder #{folder.key} (#{Placement.format_bytes(size)}) on #{target.friendly_name}"
        end
        report.placed << [folder.key, target.friendly_name]
        @placed_this_run[folder.share] |= [target.serial_number]
        free_ledger[target.serial_number] -= size.to_i
        [mounted.find { |m| m.serial_number == target.serial_number }, size, 'placed', "on #{target.friendly_name}"]
      rescue Placement::NoMountedDrives, Placement::DoesNotFit => e
        warn(report, "cannot place #{folder.key}: #{e.message}")
        report.unplaced << folder.key
        [nil, size, 'unplaced', e.is_a?(Placement::NoMountedDrives) ? 'no drive mounted' : 'no drive has room']
      end

      def sync_folder(folder, target, report)
        destination = File.join(target.mount_point, folder.key)
        @out.puts "\n------------------ #{folder.key} -> #{target.friendly_name} ------------------"
        started = @clock.now.utc.iso8601
        result = @mirror.sync(folder.path, destination, root_only: folder.root_only ? true : false)
        unless @dry_run
          manifest.record_sync(folder_path: folder.key, drive_serial: target.serial_number, started_at: started,
                               finished_at: @clock.now.utc.iso8601, exit_status: result.exit_status,
                               bytes_transferred: result.bytes_transferred, total_size_bytes: result.total_size_bytes,
                               run_started_at: @run_started_at)
        end
        if result.success?
          report.synced << folder.key
          if result.extraneous.nil?
            warn(report, "#{folder.key}: the deletion probe failed, so nothing was recorded as missing this run")
          elsif @dry_run
            @out.puts "  #{folder.key}: #{result.extraneous.size} file#{'s' if result.extraneous.size != 1} gone from the NAS would be recorded" unless result.extraneous.empty?
          else
            note_missing(folder, result.extraneous)
          end
          refetch_flagged(folder, target, destination, report)
        elsif result.disk_full?
          manifest.mark_folder_status(folder.key, 'drive_full') unless @dry_run
          warn(report, "#{folder.key} did not fully sync: #{target.friendly_name} is full " \
                       "(#{Placement.format_bytes(target.free_bytes)} free before this run). " \
                       "Move it to a drive with more room: `easy_sync reassign #{folder.key} DRIVE_NAME`, then sync.")
          report.drive_full << folder.key
        else
          warn(report, "rsync for #{folder.key} exited with status #{result.exit_status}")
          report.failed << folder.key
        end
      end

      # Re-copies files `scrub` flagged as corrupt/unreadable, overwriting the
      # bad copy on the drive - the only cost a folder with no flagged files
      # pays for this. Only called after the copy pass has already succeeded;
      # a folder skipped for any reason leaves its flags exactly as they are,
      # so the next sync tries again.
      def refetch_flagged(folder, target, destination, report)
        # A flagged file since deleted on the NAS can't be refetched (and
        # would make rsync fail the whole list with exit 23); the deletion
        # probe already tracks it for Purger, and the next scrub drops its row.
        flagged = manifest.flagged_checksums(target.serial_number, folder.key)
                          .select { |f| File.exist?(File.join(folder.path, f.relative_path)) }
        return if flagged.empty?

        if @dry_run
          @out.puts "  #{folder.key}: #{flagged.size} flagged file#{'s' if flagged.size != 1} would be refetched"
          return
        end

        result = @mirror.refetch(folder.path, destination, flagged.map(&:relative_path))
        if result.success?
          manifest.mark_refetched(target.serial_number, folder.key, flagged.map(&:relative_path))
          report.refetched << [folder.key, flagged.size]
          @out.puts "  #{folder.key}: refetched #{flagged.size} file#{'s' if flagged.size != 1} flagged by scrub"
        else
          warn(report, "#{folder.key}: refetch of #{flagged.size} scrub-flagged file#{'s' if flagged.size != 1} failed " \
                       "(rsync exit #{result.status}); will try again next sync")
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
            manifest.mark_folder_status(f.folder_path, 'skipped_source_unmounted') unless @dry_run
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
        result.skipped.each do |p, why|
          label = p.whole_folder? ? "#{p.folder_path} (whole folder)" : "#{p.folder_path}/#{p.relative_path}"
          warn(report, "not purging #{label}: #{why}")
        end
      end

      # Every mounted drive gets a fresh copy of the manifest and config in
      # its .easy_sync folder, so losing the Mac never loses the map.
      def copy_state_to_drives(mounted, report)
        return if @dry_run

        mounted.each do |m|
          @volume_info.copy_state(m.mount_point, manifest: manifest, config_path: settings[:config_path])
        rescue SystemCallError, SQLite3::Exception => e
          warn(report, "could not copy the manifest to #{m.friendly_name}: #{e.message}")
        end
      end

      # True when a folder holds no regular file apart from excluded/hidden
      # names (a show folder left with just a .DS_Store, an empty downloads
      # dir). Stops at the first real file, so a full folder costs one stat.
      def empty_source?(path)
        excluded = Array(settings[:exclude_folders])
        Dir.each_child(path) do |name|
          next if name.start_with?('.') || excluded.any? { |pat| File.fnmatch?(pat, name) }

          child = File.join(path, name)
          return false if File.file?(child)
          return false if File.directory?(child) && !empty_source?(child)
        end
        true
      rescue SystemCallError
        false   # can't tell; let rsync decide
      end

      # Drives already holding part of +share+, so its new units join them
      # while they fit (Placement prefers these). Includes this run's own
      # placements, which a dry run never writes to the manifest.
      def share_drives(share)
        placed = manifest.folders.select { |f| f.share == share }.map(&:drive_serial)
        (placed + @placed_this_run[share]).uniq
      end

      def loose_bytes(path)
        loose_files(path).sum { |n| File.size(File.join(path, n)) }
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
                  "unplaced #{report.unplaced.size}, empty #{report.empty.size}, purged #{report.purged.size}, " \
                  "#{report.pending.to_i} pending deletion#{'s' if report.pending.to_i != 1}, warnings #{report.warnings.size}"
        refetched_files = report.refetched.sum { |_, count| count }
        return unless refetched_files.positive?

        @out.puts "Refetched #{refetched_files} file#{'s' if refetched_files != 1} flagged by scrub, " \
                  "across #{report.refetched.size} folder#{'s' if report.refetched.size != 1}"
      end
    end
  end
end
