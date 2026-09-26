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

      def initialize(manifest, grace_days: 7, scrub_stale_days: 30, clock: Time, mount_root: '/Volumes',
                     backblaze_dir: Backblaze::DATA_DIR)
        @manifest = manifest
        @mount_root = mount_root
        @backblaze_dir = backblaze_dir
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
      def render(mounted: [], source_status: {}, running: nil)
        @running = running
        by_serial = mounted.to_h { |m| [m.serial_number, m] }
        drives = manifest.drives.map { |d| drive_view(d, by_serial[d.serial_number]) }
        runs = manifest.run_summaries(limit: RUNS_SHOWN)
        inventory = manifest.source_inventory
        folders = manifest.folders
        names = manifest.drives(include_retired: true).to_h { |d| [d.serial_number, d.retired? ? "#{d.friendly_name} (retired)" : d.friendly_name] }
        scrub_findings = manifest.scrub_findings
        backblaze = Backblaze.read(@backblaze_dir)
        @backblaze_installed = !backblaze.nil?
        uploads = backblaze&.drive_states(manifest.drives, mounted: by_serial, mount_root: @mount_root,
                                                           last_copied_at: manifest.last_copied_at)
        trips = current_trips(runs)
        issues = issues(drives: drives, folders: folders, inventory: inventory, source_status: source_status,
                        runs: runs, scrub_findings: scrub_findings, trips: trips)
        locals = {
          drives: drives,
          folders: folders,
          names: names,
          issues: issues,
          verdict: verdict(issues, inventory, folders, source_status, trips),
          trips: trips,
          accepted_trips: manifest.accepted_trips(limit: ACCEPTED_TRIPS_SHOWN),
          activity: activity_days(history_groups(manifest.history(limit: HISTORY_ROWS)),
                                  deletion_groups(manifest.deletions(limit: HISTORY_ROWS)), runs, names),
          runs: runs,
          latest_notable: runs.empty? ? [] : manifest.notable_sync_runs(runs.first.run_started_at),
          generated_at: @clock.now,
          total_capacity_bytes: drives.sum { |d| d.capacity_bytes.to_i },
          total_free_bytes: drives.sum { |d| d.free_bytes.to_i },
          source_status: source_status,
          pending: manifest.pending_deletions,
          inventory: inventory,
          scrub_findings: scrub_findings,
          uploads: uploads,
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

      # -- status: what needs you ------------------------------------------

      # Backblaze Personal drops a drive from the current backup once it has
      # not been connected for 30 days (history keeps it for a year). Warn
      # with time to act; only when Backblaze is installed, since without it
      # a drive left disconnected is the normal state between syncs.
      BACKBLAZE_WARN_DAYS = 21
      BACKBLAZE_DROP_DAYS = 30
      STALE_SYNC_DAYS = 7
      RUNS_SHOWN = 30
      ACCEPTED_TRIPS_SHOWN = 10

      # The tripwire's unaccepted trips from the latest run, unless a later
      # run has synced since. A stopped run records no sync_runs, so its
      # trips outrank the last run that did copy; a folder-only trip shares
      # its run_started_at with the folders that did copy.
      def current_trips(runs)
        latest = manifest.latest_trips.reject(&:accepted?)
        return [] if latest.empty?
        return [] if runs.first && runs.first.run_started_at > latest.first.run_started_at

        latest
      end

      def run_stopped?(trips) = trips.any? { |t| t.scope == 'run' }

      Issue = Struct.new(:level, :html, keyword_init: true)
      Verdict = Struct.new(:level, :headline, keyword_init: true)

      # Everything worth your attention, most serious first. Each is one line
      # of trusted HTML (every interpolated value is escaped here).
      def issues(drives:, folders:, inventory:, source_status:, runs:, scrub_findings:, trips: [])
        list = []
        if run_stopped?(trips)
          list << Issue.new(level: :critical,
                            html: "<strong>The last sync was stopped by the tripwire</strong> #{when_(trips.first.run_started_at)}: " \
                                  "#{count(trips.sum(&:changed))} existing files would have been overwritten or are gone from the NAS. " \
                                  'Nothing was copied or purged. Check the NAS for ransomware first; if you made this change yourself, ' \
                                  'run <code>easy_sync sync --accept-changes</code> (see Tripwire).')
        elsif trips.any?
          list << Issue.new(level: :critical,
                            html: "<strong>#{trips.size} folder#{'s' if trips.size != 1} held back by the tripwire</strong>: " \
                                  'far more of their files would change than normal, so they were not copied. ' \
                                  'Check them on the NAS (see Tripwire).')
        end
        unplaced = inventory.select { |e| e.state == 'unplaced' }
        unless unplaced.empty?
          list << Issue.new(level: :critical,
                            html: "<strong>#{count(unplaced.size)} folder#{'s' if unplaced.size != 1} " \
                                  "(#{bytes(unplaced.sum { |e| e.size_bytes.to_i })}) on the NAS " \
                                  "#{unplaced.size == 1 ? 'is' : 'are'} not backed up</strong>: no drive has room. " \
                                  'Add or replace a drive, then sync again (list under Folders).')
        end
        drives.select { |d| %i[warning critical].include?(d.level) }.each do |d|
          name = h(d.drive.friendly_name)
          list << Issue.new(level: d.level,
                            html: "<strong>#{name} #{d.level == :critical ? 'is FAILING' : 'is starting to fail'}</strong>: " \
                                  "SMART says #{h d.drive.smart_detail} (checked #{when_(d.drive.smart_checked_at)}). " \
                                  "Register a new drive, then <code>easy_sync replace-drive #{name} --to NEW_NAME --copy</code>.")
        end
        drives.each do |d|
          days = unseen_days(d)
          next unless @backblaze_installed && days && days >= BACKBLAZE_WARN_DAYS

          name = h(d.drive.friendly_name)
          list << if days >= BACKBLAZE_DROP_DAYS
                    Issue.new(level: :critical,
                              html: "<strong>#{name} not connected for #{days} days</strong>: it has dropped out of " \
                                    "Backblaze's current backup (history keeps it for a year). Connect it and let Backblaze catch up.")
                  else
                    Issue.new(level: :warning,
                              html: "<strong>#{name} not connected for #{days} days</strong>: Backblaze drops it from the " \
                                    "current backup at #{BACKBLAZE_DROP_DAYS}. Connect it within #{BACKBLAZE_DROP_DAYS - days} days.")
                  end
        end
        bad = folders.reject { |f| NEUTRAL.include?(folder_status(f, source_status)) }
        unless bad.empty?
          list << Issue.new(level: :warning,
                            html: "<strong>#{count(bad.size)} folder#{'s' if bad.size != 1} not in a good state</strong> " \
                                  '(failed, drive full, held back, missing on the NAS or not mounted): see Needs attention under Folders.')
        end
        latest = runs.first
        if latest && latest.failed.to_i.positive?
          list << Issue.new(level: :warning,
                            html: "<strong>The last sync had #{latest.failed} failure#{'s' if latest.failed != 1}</strong>; " \
                                  'they are retried on the next sync (see Latest sync).')
        end
        if latest && days_ago(latest.run_started_at) >= STALE_SYNC_DAYS
          list << Issue.new(level: :warning,
                            html: "<strong>No sync for #{days_ago(latest.run_started_at)} days</strong>: run <code>easy_sync sync</code>.")
        end
        unless scrub_findings.empty?
          list << Issue.new(level: :critical,
                            html: "<strong>#{count(scrub_findings.size)} file#{'s' if scrub_findings.size != 1} flagged by scrub</strong> " \
                                  '(rot or read errors): see Scrub findings.')
        end
        overdue = drives.select { |d| scrub_overdue?(d) }
        unless overdue.empty?
          list << Issue.new(level: :warning,
                            html: "<strong>#{overdue.size} drive#{'s' if overdue.size != 1} overdue for a scrub</strong> " \
                                  "(#{h overdue.map { |d| d.drive.friendly_name }.join(', ')}): <code>easy_sync scrub --all</code>.")
        end
        list.sort_by { |i| i.level == :critical ? 0 : 1 }
      end

      def verdict(issues, inventory, folders, source_status, trips = [])
        level = if issues.any? { |i| i.level == :critical } then :critical
                elsif issues.any? then :warning
                else :ok
                end
        total = inventory.empty? ? folders.size : inventory.count { |e| e.state != 'empty' }
        unplaced = inventory.count { |e| e.state == 'unplaced' }
        # Backed up = copied at least once. A folder whose drive was simply
        # offline for the last sync still is; one never copied is not.
        backed = [folders.count(&:last_synced_at), total].min
        waiting = unsynced_in(folders, source_status)
        headline = if run_stopped?(trips) then "Sync stopped: #{count(trips.sum(&:changed))} files would change on the NAS side"
                   elsif total.zero? then 'Nothing backed up yet'
                   elsif unplaced.positive? then "#{count(unplaced)} of #{count(total)} folders are not backed up"
                   elsif backed == total then "All #{count(total)} folders backed up"
                   elsif waiting.positive? then "#{count(backed)} of #{count(total)} folders backed up, #{count(waiting)} waiting for their first copy"
                   else "#{count(backed)} of #{count(total)} folders backed up"
                   end
        Verdict.new(level: level, headline: headline)
      end

      # Days since a drive was last connected; nil while it is connected now.
      def unseen_days(view)
        return nil if view.mounted || view.drive.last_seen_at.nil?

        days_ago(view.drive.last_seen_at)
      end

      def seen_level(view)
        days = unseen_days(view) or return nil
        return nil unless @backblaze_installed
        return 'critical' if days >= BACKBLAZE_DROP_DAYS

        'warning' if days >= BACKBLAZE_WARN_DAYS
      end

      # -- activity feed ---------------------------------------------------

      ActivityItem = Struct.new(:at, :kind, :summary, :note, :items, keyword_init: true)

      # Sync runs, placement changes and deletions in one newest-first feed,
      # grouped by local day: [[day_label, [ActivityItem, ...]], ...].
      def activity_days(history, deletions, runs, names)
        items = runs.map do |r|
          summary = in_progress?(r, runs) ? "Sync in progress: #{count(r.folders)} folder#{'s' if r.folders != 1} checked so far" : run_line(r)
          ActivityItem.new(at: r.run_started_at, kind: 'sync', summary: summary, note: nil, items: [])
        end
        # A removal is already in the feed as its deletion from the drive.
        items += history.reject { |g| g.event == 'removed' }.map do |g|
          ActivityItem.new(at: g.at, kind: g.event, summary: history_summary(g, names), note: readable_note(g.note, names),
                           items: g.items.size == 1 ? [] : g.items.map { |e| history_item(e, g, names) })
        end
        items += deletions.map do |g|
          drive = names.fetch(g.drive_serial, g.drive_serial)
          single = g.items.size == 1
          ActivityItem.new(at: g.at, kind: 'deleted',
                           summary: "#{single ? deletion_label(g.items.first) : deletion_summary(g)} deleted from #{drive}",
                           note: single ? deletion_reason(g.items.first) : nil,
                           items: single ? [] : g.items.map { |d| "#{deletion_label(d)} (#{deletion_reason(d)})" })
        end
        items.sort_by(&:at).reverse.first(ACTIVITY_SHOWN).group_by { |i| day_label(i.at) }.to_a
      end

      ACTIVITY_SHOWN = 40

      def run_line(run)
        copied = run.copied.to_i.zero? ? 'nothing to copy' : "#{count(run.copied)} copied (#{bytes(run.bytes_transferred)})"
        failed = run.failed.to_i.positive? ? ", #{run.failed} failed" : ''
        "Sync: #{count(run.folders)} folder#{'s' if run.folders != 1} checked, #{copied}#{failed} in #{run_duration(run)}"
      end

      # -- template helpers ------------------------------------------------

      # 2692 -> "2,692"
      def count(n) = n.to_i.to_s.reverse.scan(/\d{1,3}/).join(',').reverse

      # "today 20:18", "yesterday 08:50", "Sep 21 13:45" (or with the year
      # when it isn't this year).
      def relative_when(iso)
        return 'never' if iso.nil? || iso.empty?

        t = Time.parse(iso).localtime
        "#{day_label(iso).sub(/\A(Today|Yesterday)\z/) { |w| w.downcase }} #{t.strftime('%H:%M')}"
      end

      def day_label(iso)
        t = Time.parse(iso).localtime
        today = @clock.now.localtime.to_date
        return 'Today' if t.to_date == today
        return 'Yesterday' if t.to_date == today - 1

        t.year == today.year ? t.strftime('%a %b %-d') : t.strftime('%a %b %-d %Y')
      end

      def bytes(value) = Placement.format_bytes(value)

      # Enough raw rows to fill GROUPS_SHOWN groups even when one bulk
      # operation (a first placement, a reassign of dozens of folders)
      # produced thousands of them.
      HISTORY_ROWS = 5_000
      GROUPS_SHOWN = 20

      # Rows recorded in the same minute for the same reason, as one line: a
      # bulk operation (a first placement across every drive, a reassign of
      # dozens of folders) reads as one event instead of pushing everything
      # else off the list. The note's trailing "(4.8 TB free)"-style detail
      # differs row to row within one batch, so it is left out of the match.
      HistoryGroup = Struct.new(:at, :event, :note, :items, keyword_init: true) do
        def drive_serials = items.map(&:drive_serial).uniq
      end
      DeletionGroup = Struct.new(:at, :drive_serial, :items, keyword_init: true) do
        def folders = items.count { |d| d.kind == 'folder' }
        def files = items.size - folders
      end

      def history_groups(entries)
        group_rows(entries, ->(e) { [minute(e.recorded_at), e.event, note_gist(e.note)] }).map do |g|
          HistoryGroup.new(at: g.first.recorded_at, event: g.first.event,
                           note: g.size == 1 ? g.first.note : note_gist(g.first.note), items: g)
        end
      end

      def deletion_groups(deletions)
        group_rows(deletions, ->(d) { [minute(d.deleted_at), d.drive_serial] }).map do |g|
          DeletionGroup.new(at: g.first.deleted_at, drive_serial: g.first.drive_serial, items: g)
        end
      end

      # Newest first, like the rows themselves.
      def group_rows(rows, key) = rows.group_by { |r| key.call(r) }.values.first(GROUPS_SHOWN)

      def minute(iso) = iso.to_s[0, 16]
      def note_gist(note) = note.to_s.sub(/\s*\([^()]*\)\z/, '')

      EVENT_VERBS = { 'assigned' => 'placed on', 'reassigned' => 'moved to', 'removed' => 'deleted from',
                      'split' => 'split on' }.freeze

      # "3 folders placed on backup-07-6tb" / "2,666 folders placed on 8
      # drives", or the folder itself when alone.
      def history_summary(group, names)
        serials = group.drive_serials
        where = serials.size == 1 ? names.fetch(serials.first, serials.first) : "#{serials.size} drives"
        what = group.items.size == 1 ? group.items.first.folder_path : "#{group.items.size} folders"
        "#{what} #{EVENT_VERBS.fetch(group.event, group.event)} #{where}"
      end

      def history_item(entry, group, names)
        return entry.folder_path if group.drive_serials.size == 1

        "#{entry.folder_path} → #{names.fetch(entry.drive_serial, entry.drive_serial)}"
      end

      def deletion_summary(group)
        parts = []
        parts << "#{group.folders} folder#{'s' if group.folders != 1}" if group.folders.positive?
        parts << "#{group.files} file#{'s' if group.files != 1}" if group.files.positive?
        parts.join(' and ')
      end

      def deletion_label(d) = d.kind == 'folder' ? "#{d.folder_path} (whole folder)" : "#{d.folder_path}/#{d.relative_path}"

      # The old copy a move left behind is recorded with its drive's serial
      # where a path would be (see PendingDeletion); it was never missing.
      def moved_copy?(d) = d.kind == 'folder' && d.relative_path == d.drive_serial

      def deletion_reason(d)
        moved_copy?(d) ? "old copy, after the move on #{when_(d.first_missing_at)}" : "missing on the NAS since #{when_(d.first_missing_at)}"
      end

      # Notes written by earlier code name drives by serial ("moved from
      # SN-EXAMPLE1"); show the drive's name instead, and timestamps the way the
      # rest of the page does. A removal's note repeats "deleted from <drive>:",
      # which the line itself already says.
      def readable_note(note, names)
        text = names.reduce(note.to_s) { |t, (serial, name)| t.gsub(serial, name) }
        text = text.sub(/\Adeleted from [^:]+: /, '')
        text.gsub(/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ/) { |iso| when_(iso) }
      end

      # "2h 14m" from a run's start to its last folder finishing.
      def run_duration(run)
        return '—' unless run.last_finished_at

        Placement.format_duration(Time.parse(run.last_finished_at) - Time.parse(run.run_started_at))
      end

      # The newest run is still going when a sync holds the lock and started
      # no later than it (the lock is taken just before the run begins).
      def in_progress?(run, runs)
        @running&.kind == 'sync' && run.equal?(runs.first) &&
          @running.started_at.utc.iso8601 <= run.run_started_at
      end

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

      # Groups folders by share (the first path segment): "tv" groups every
      # "tv/<show>" plus the share's own root-files unit, or a share placed
      # whole by an earlier build. Returns [[share, [folders...]], ...] in share order.
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
        'skipped_unmounted' => 'drive not mounted', 'drive_full' => 'drive full',
        'tripped' => 'held back by tripwire', 'skipped_check_failed' => 'check failed'
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

      # The header's Backblaze clause: whether the drives can be powered off
      # without leaving anything waiting to upload.
      def backblaze_summary(uploads)
        pending = uploads.values.count { |u| !u.done? }
        pending.zero? ? 'Backblaze up to date' : "Backblaze: #{pending} drive#{'s' if pending != 1} not up to date"
      end

      # "scrubbing now", "scrubbed N days ago", or "never scrubbed", shown on
      # every drive tile regardless of whether it's overdue.
      def scrub_status_line(view)
        return 'scrubbing now' if scrubbing?(view)

        through = manifest.scrubbed_through(view.drive.serial_number)
        return 'never scrubbed' unless through

        days = days_ago(through)
        "scrubbed #{days} day#{'s' if days != 1} ago"
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

      # "connected", or "last seen 3 days ago" for a drive not mounted now.
      def seen_line(view)
        return nil if view.mounted
        return 'never seen' unless view.drive.last_seen_at

        days = days_ago(view.drive.last_seen_at)
        days.zero? ? "last seen #{relative_when(view.drive.last_seen_at)}" : "last seen #{days} day#{'s' if days != 1} ago"
      end

      def scrub_finding_phrase(row)
        return 'unresolved: compare with the NAS copy' if row.status == 'unresolved'
        return 'refetched, awaiting re-check' if row.refetched_at

        'awaiting refetch'
      end
    end
  end
end
