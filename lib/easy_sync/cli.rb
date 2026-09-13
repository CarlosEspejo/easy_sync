# frozen_string_literal: true

require 'optparse'

module EasySync
  # Command-line entry point.
  class CLI
    # [group, [[command, description], ...]] in the order a new user meets them.
    COMMAND_GROUPS = [
      ['Set up, once', [
        ['add-source PATH [--split | --whole]', 'add a NAS share (mounted on this Mac); split/whole is inferred unless given'],
        ['register-drive MOUNT_POINT [--name NAME] [--serial SERIAL]', 'add a backup drive (mounted and unlocked)'],
        ['plan [SHARE ...] [--largest-drive SIZE] [--apply]', 'measure each share (or just the ones named) and recommend split or whole; --apply writes it']
      ]],
      ['Back up', [
        ['sync [--dry-run] [--no-purge] [--no-keep-awake]', 'mirror the shares onto the drives'],
        ['status', 'whether a sync is running, drives, their health, and folders'],
        ['dashboard', 'regenerate the HTML report']
      ]],
      ['Maintain', [
        ['pending', 'deletion candidates and when each expires'],
        ['clean [--dry-run]', 'remove excluded junk (#recycle, .DS_Store, ...) from the drives now'],
        ['history [FOLDER]', 'where a folder has lived'],
        ['reassign FOLDER DRIVE_NAME [--note TEXT]', 'record a move you made by hand (moves no data)'],
        ['replace-drive OLD_NAME [--to NEW_NAME] [--copy]', 'retire a drive; hand its folders to NEW, or let the next sync re-place them'],
        ['remove-source PATH', 'stop backing up a share (drives are left alone)'],
        ['sources', 'list the configured shares']
      ]]
    ].freeze

    USAGE = begin
      width = COMMAND_GROUPS.flat_map { |_, cmds| cmds.map { |c, _| c.length } }.max + 2
      lines = ['Usage: easy_sync [--config PATH] <command> [options]', '']
      COMMAND_GROUPS.each do |group, cmds|
        lines << "#{group}:"
        cmds.each { |c, d| lines << "  #{c.ljust(width)}#{d}" }
        lines << ''
      end
      lines << 'Global options:'
      lines << "  #{'--config PATH'.ljust(width)}use this config file (default ~/.easy_sync/config.yml; EASY_SYNC_CONFIG does the same)"
      lines << "  #{'--version'.ljust(width)}print the version"
      lines << "  #{'--help'.ljust(width)}this text"
      "#{lines.join("\n")}\n"
    end

    def initialize(argv, out: $stdout, err: $stderr, config_path: nil, shell: Shell.new, env: ENV,
                   keep_awake: Jbod::KeepAwake.new, clock: Time)
      @argv = argv.dup
      @out = out
      @err = err
      @shell = shell
      @keep_awake = keep_awake
      @clock = clock
      @config_path = config_path || env['EASY_SYNC_CONFIG'] || Config.default_path
    end

    def run
      parse_global_options!
      command = @argv.shift
      case command
      when nil, '-h', '--help', 'help'
        @out.puts USAGE
        @out.puts get_started_hint if nothing_configured?
      when '-v', '--version', 'version' then @out.puts "easy_sync #{VERSION}"
      when 'add-source' then add_source(@argv)
      when 'remove-source' then remove_source(@argv)
      when 'sources' then list_sources
      when 'sync' then sync(@argv)
      when 'register-drive' then register_drive(@argv)
      when 'replace-drive' then replace_drive(@argv)
      when 'status' then status
      when 'history' then history(@argv.first)
      when 'reassign' then reassign(@argv)
      when 'pending' then pending
      when 'clean' then clean(@argv)
      when 'plan' then plan(@argv)
      when 'dashboard' then dashboard
      else
        @err.puts "Unknown command: #{command}\n\n#{USAGE}"
        return 1
      end
      0
    rescue Error, OptionParser::ParseError => e
      @err.puts "error: #{e.message}"
      1
    rescue Interrupt
      # Ctrl-C. Everything is resumable: the lock and log are released by
      # their ensure blocks, caffeinate exits with us, rsync's own temp file for
      # the in-flight copy is removed by rsync, and the folder that was being
      # synced simply syncs again next run.
      @err.puts "\nInterrupted. Nothing is lost: run `easy_sync sync` again to pick up where this left off."
      130
    end

    private

    # Help must never fail, whatever state the config is in.
    def nothing_configured?
      config.source_entries.empty?
    rescue StandardError
      false
    end

    def get_started_hint
      "Nothing is configured yet. To get started:\n" \
        "  easy_sync add-source /Volumes/<share>            once per NAS share\n" \
        "  easy_sync register-drive /Volumes/<drive>        once per backup drive\n" \
        "  easy_sync plan --apply\n" \
        "  easy_sync sync --dry-run\n" \
        "  easy_sync sync\n"
    end

    # Global options come before the command: `easy_sync --config x sync`.
    def parse_global_options!
      while (arg = @argv.first)
        case arg
        when '--config'
          @argv.shift
          @config_path = @argv.shift or raise Error, "--config needs a path\n\n#{USAGE}"
        when /\A--config=(.+)\z/
          @argv.shift
          @config_path = Regexp.last_match(1)
        else
          break
        end
      end
    end

    def config
      @config ||= begin
        cfg, status = Config.load(@config_path)
        @err.puts "Generated sample config file: #{@config_path}" if status == :generated
        cfg
      end
    end

    def settings = config.settings

    def manifest
      @manifest ||= Jbod::Manifest.open(settings[:manifest_path])
    end

    def volume_info
      @volume_info ||= Jbod::VolumeInfo.new(mount_root: settings[:mount_root], shell: @shell)
    end

    def sync(args)
      opts = { dry_run: false, purge: nil, keep_awake: settings.fetch(:keep_awake, true) }
      OptionParser.new do |o|
        o.on('--dry-run', 'Show what rsync and the purge would do without changing anything') { opts[:dry_run] = true }
        o.on('--no-purge', 'Sync but do not delete expired files from the drives') { opts[:purge] = false }
        o.on('--no-keep-awake', 'Let the Mac sleep during this run (default: caffeinate keeps it awake)') { opts[:keep_awake] = false }
      end.parse!(args)
      version = Jbod::Mirror.check_version!(@shell)
      Jbod::RunLock.new(settings[:lock_path]).acquire do
        log = Jbod::RunLog.open(settings[:log_dir], keep: settings[:keep_logs], out: @out, clock: @clock)
        begin
          log.puts "easy_sync #{VERSION} · #{@clock.now.strftime('%Y-%m-%d %H:%M:%S %Z')} · rsync #{version}" \
                   "#{' · DRY RUN' if opts[:dry_run]} · log #{log.path}"
          log.puts 'Keeping the Mac awake for this run (caffeinate).' if opts[:keep_awake] && @keep_awake.start
          Jbod::Runner.new(settings, manifest: manifest, volume_info: volume_info, shell: @shell.with_out(log),
                                     out: log, dry_run: opts[:dry_run], purge: opts[:purge], clock: @clock).run
        ensure
          log.close
        end
      end
    end

    # Removes anything matching exclude_folders from the placed folders on
    # every mounted drive, without waiting for the deletion grace period.
    def clean(args)
      dry_run = false
      OptionParser.new { |o| o.on('--dry-run', 'List what would be removed') { dry_run = true } }.parse!(args)
      # A dry run only reads, so it may look while a sync is running.
      lock = dry_run ? ->(&blk) { blk.call } : Jbod::RunLock.new(settings[:lock_path]).method(:acquire)
      lock.call do
        mounted = volume_info.mounted_drives(manifest.drives)
        raise Error, 'no registered drive is mounted' if mounted.empty?

        @out.puts "#{dry_run ? 'Would remove' : 'Removing'} entries matching #{settings[:exclude_folders].join(', ')} " \
                  "from #{mounted.map(&:friendly_name).join(', ')}:"
        result = Jbod::Cleaner.new(manifest, excludes: settings[:exclude_folders], out: @out).run(mounted, dry_run: dry_run)
        if dry_run
          @out.puts "#{result.would_remove.size} entr#{result.would_remove.size == 1 ? 'y' : 'ies'} would be removed."
        else
          @out.puts "Removed #{result.removed.size} entr#{result.removed.size == 1 ? 'y' : 'ies'}, " \
                    "#{Jbod::Placement.format_bytes(result.bytes)} freed."
        end
      end
    end

    def pending
      rows = manifest.pending_deletions
      if rows.empty?
        @out.puts 'Nothing is pending deletion.'
        return
      end
      now = Time.now
      @out.puts "#{rows.size} pending (deleted after #{settings[:grace_days]} days and #{settings[:grace_runs]} runs missing):"
      rows.each do |p|
        label = p.whole_folder? ? "#{p.folder_path} (whole folder)" : "#{p.folder_path}/#{p.relative_path}"
        state = p.expired?(now: now, grace_days: settings[:grace_days], grace_runs: settings[:grace_runs]) ? 'EXPIRED, deleted on next sync' \
                : "expires #{p.expires_at(settings[:grace_days]).strftime('%Y-%m-%d')}, seen missing #{p.missing_runs}x"
        @out.puts "  #{label.ljust(50)} since #{p.first_missing_at}  #{state}"
      end
    end

    # Adds a share. Without --split/--whole the setting is inferred: loose
    # files at the top level force whole; otherwise, if a drive is registered
    # the planner's rule decides, else split (safe for any size; `plan --apply`
    # refines it once drives exist).
    def add_source(args)
      opts = {}
      OptionParser.new do |o|
        o.on('--split', 'Place each subfolder on its own (for shares bigger than one drive)') { opts[:split] = true }
        o.on('--whole', 'Place the whole share as one unit on one drive') { opts[:split] = false }
      end.parse!(args)
      path = args.first or raise Error, "add-source needs the share's path, e.g. /Volumes/tv\n\n#{USAGE}"
      path = File.expand_path(path)
      raise Error, "#{path} is not mounted (or is empty)" unless Dir.exist?(path) && !Dir.empty?(path)

      split, why = opts.key?(:split) ? [opts[:split], 'as you asked'] : infer_split(path)
      config.add_source(path, split: split)
      config.save
      @out.puts "Added #{path} (split: #{split}, #{why}). Config: #{config.path}"
      @out.puts 'Run `easy_sync plan` after registering your drives to check the split settings.' unless opts.key?(:split)
    end

    def infer_split(path)
      excluded = settings[:exclude_folders]
      children = Dir.children(path).reject { |n| n.start_with?('.') || excluded.any? { |pat| File.fnmatch?(pat, n) } }
      loose = children.count { |n| File.file?(File.join(path, n)) }
      dirs = children.count { |n| File.directory?(File.join(path, n)) }
      return [false, "#{loose} loose file#{'s' if loose != 1} at the top level; only a whole share backs those up"] if loose.positive?
      return [false, 'no subfolders to split by'] if dirs.zero?

      largest = manifest.drives.map(&:capacity_bytes).max
      return [true, 'no drive registered yet, so split, which works for any size; `plan --apply` will refine it'] unless largest

      # A drive to judge against: measure the share (du) and apply the planner's rule.
      row = Jbod::Planner.new(settings.merge(sources: [{ path: path, split: true }]), shell: @shell,
                                                                                    largest_drive_bytes: largest).rows.first
      [row.recommend_split, row.reason]
    end

    def remove_source(args)
      path = args.first or raise Error, "remove-source needs the share's path\n\n#{USAGE}"
      config.remove_source(File.expand_path(path))
      config.save
      @out.puts "Removed #{File.expand_path(path)}. Nothing on the drives was touched; folders already placed stay " \
                'in the manifest (they will be reported as missing on the NAS and follow the deletion grace period).'
    end

    def list_sources
      entries = config.source_entries
      if entries.empty?
        @out.puts "No sources configured. Add one with: easy_sync add-source /Volumes/<share>"
        return
      end
      entries.each do |e|
        state = Dir.exist?(e[:path]) && !Dir.empty?(e[:path]) ? 'mounted' : 'NOT MOUNTED'
        @out.puts "  #{e[:path].ljust(32)} #{(e[:split] ? 'split' : 'whole').ljust(6)} #{state}"
      end
    end

    # Measures every configured share and says whether to split it.
    def plan(args)
      opts = {}
      OptionParser.new do |o|
        o.on('--largest-drive SIZE', 'Capacity of the biggest drive you will register, e.g. 8tb (default: from the manifest)') do |v|
          opts[:largest] = Jbod::Placement.parse_size(v)
        end
        o.on('--apply', 'Write the recommended split settings to the config') { opts[:apply] = true }
      end.parse!(args)
      only = args.empty? ? nil : args
      largest = opts[:largest] || manifest.drives.map(&:capacity_bytes).max
      @out.puts(largest ? "Judging against the largest drive: #{Jbod::Placement.format_bytes(largest)}" \
                        : 'No drives registered yet; pass --largest-drive 8tb for recommendations')
      rows = Jbod::Planner.new(settings, shell: @shell, largest_drive_bytes: largest).rows(only: only)
      raise Error, "no configured source matches #{only.join(', ')}" if only && rows.empty?

      rows.each do |r|
        @out.puts "\n#{r.source.path}"
        unless r.mounted
          @out.puts "  #{r.reason}"
          next
        end
        @out.puts "  #{Jbod::Placement.format_bytes(r.size_bytes)} in #{r.subfolders} folder#{'s' if r.subfolders != 1}" \
                  "#{r.largest_name ? ", largest #{r.largest_name} (#{Jbod::Placement.format_bytes(r.largest_subfolder)})" : ''}" \
                  "#{r.loose_files.positive? ? ", #{r.loose_files} loose file#{'s' if r.loose_files != 1}" : ''}"
        @out.puts "  currently split: #{r.source.split}"
        @out.puts "  recommend split: #{r.recommend_split.nil? ? '?' : r.recommend_split}  (#{r.reason})"
        @out.puts '  -> CHANGE the config to match' if r.mismatch?
      end
      changes = rows.select(&:mismatch?)
      if opts[:apply]
        changes.each { |r| config.set_split(r.source.path, r.recommend_split) }
        config.save if changes.any?
        @out.puts(changes.empty? ? "\nConfig already matches the recommendations." \
                                 : "\nUpdated #{changes.size} source#{'s' if changes.size != 1} in #{config.path}.")
      elsif changes.any?
        suggestion = (['easy_sync plan'] + Array(only) + ['--apply']).join(' ')
        @out.puts "\nRun `#{suggestion}` to write these recommendations to the config."
      end
    end

    def register_drive(args)
      opts = {}
      OptionParser.new do |o|
        o.on('--name NAME', 'Friendly name, e.g. backup-04-8tb (defaults to the volume name)') { |v| opts[:name] = v }
        o.on('--serial SERIAL', 'Serial to use, skipping auto-detection (default: smartctl, falling back to the APFS Volume UUID)') { |v| opts[:serial] = v }
      end.parse!(args)
      mount_point = args.first or raise Error, "register-drive needs a mount point\n\n#{USAGE}"
      raise Error, "#{mount_point} is not mounted" unless Dir.exist?(mount_point)

      existing = volume_info.read_marker(mount_point)
      raise Error, "#{mount_point} already carries a marker for #{existing[:serial_number]} (#{existing[:friendly_name]})" if existing

      name = opts[:name] || File.basename(mount_point)
      uuid = volume_info.volume_uuid(mount_point)
      serial, source = resolve_serial(opts[:serial], mount_point, uuid)
      serial or raise Error, 'could not determine a serial via smartctl or diskutil; pass --serial'
      @out.puts "Using #{source} as the serial number." unless opts[:serial]
      usage = volume_info.usage(mount_point)

      drive = manifest.register_drive(serial_number: serial, friendly_name: name,
                                      capacity_bytes: usage.capacity_bytes, volume_uuid: uuid)
      manifest.update_drive_usage(serial, used_bytes: usage.used_bytes, free_bytes: usage.free_bytes)
      health = volume_info.smart_health(mount_point)
      manifest.update_drive_health(serial, status: health.status, detail: health.detail)
      volume_info.write_marker(mount_point, serial_number: serial, friendly_name: name)
      @out.puts "Registered #{drive.friendly_name} (#{drive.serial_number}), " \
                "#{Jbod::Placement.format_bytes(drive.capacity_bytes)} at #{mount_point}"
      @out.puts "SMART: #{health.status} (#{health.detail})"
    end

    # Retires OLD. With --to NEW every folder on OLD is recorded as living on
    # NEW; without it the folders are forgotten so the next sync places them
    # afresh across whatever is mounted. --copy first rsyncs OLD's contents to
    # NEW over the local bus (both must be mounted), so a readable old drive
    # never has to be re-pulled from the NAS.
    def replace_drive(args)
      opts = { copy: false }
      OptionParser.new do |o|
        o.on('--to NEW_NAME', 'Registered drive that takes over every folder of the old one') { |v| opts[:to] = v }
        o.on('--copy', 'Copy the old drive onto the new one locally first (both mounted)') { opts[:copy] = true }
        o.on('--note TEXT') { |v| opts[:note] = v }
      end.parse!(args)
      old_name = args.first or raise Error, "replace-drive needs the old drive's name\n\n#{USAGE}"
      old = manifest.drive_by_name(old_name) or raise Error, "no drive named #{old_name}"
      raise Error, "#{old_name} is already retired" if old.retired?

      new_drive = nil
      if opts[:to]
        new_drive = manifest.drive_by_name(opts[:to]) or raise Error, "no drive named #{opts[:to]}; register it first"
        raise Error, "#{opts[:to]} is retired" if new_drive.retired?
        raise Error, 'old and new drive are the same' if new_drive.serial_number == old.serial_number
      end
      raise Error, '--copy needs --to NEW_NAME' if opts[:copy] && !new_drive

      folders = manifest.folders_on(old.serial_number)
      copy_drive(old, new_drive) if opts[:copy]

      note = opts[:note] || (new_drive ? "#{old.friendly_name} replaced by #{new_drive.friendly_name}" : "#{old.friendly_name} retired")
      manifest.move_all_folders(old.serial_number, new_drive&.serial_number, note: note)
      manifest.retire_drive(old.serial_number)

      @out.puts "Retired #{old.friendly_name}."
      if new_drive
        @out.puts "#{folders.size} folder#{'s' if folders.size != 1} now recorded on #{new_drive.friendly_name}."
        @out.puts(opts[:copy] ? 'Run `easy_sync sync` to verify them against the NAS.' \
                              : 'Run `easy_sync sync` to copy them there from the NAS.')
      else
        @out.puts "#{folders.size} folder#{'s' if folders.size != 1} forgotten; the next `easy_sync sync` will place " \
                  'them afresh across the mounted drives and copy them from the NAS.'
      end
    end

    # rsync OLD -> NEW over the local bus, excluding each drive's own .easy_sync folder.
    def copy_drive(old, new_drive)
      mounted = volume_info.mounted_drives([old, new_drive]).to_h { |m| [m.serial_number, m] }
      src = mounted[old.serial_number] or raise Error, "#{old.friendly_name} is not mounted (needed for --copy)"
      dst = mounted[new_drive.serial_number] or raise Error, "#{new_drive.friendly_name} is not mounted (needed for --copy)"
      if src.used_bytes > dst.free_bytes
        raise Error, "#{new_drive.friendly_name} has #{Jbod::Placement.format_bytes(dst.free_bytes)} free but " \
                     "#{old.friendly_name} holds #{Jbod::Placement.format_bytes(src.used_bytes)}"
      end
      @out.puts "Copying #{old.friendly_name} -> #{new_drive.friendly_name} (#{Jbod::Placement.format_bytes(src.used_bytes)})..."
      excludes = (settings[:exclude_folders] + [Jbod::DRIVE_DIR]).map { |e| "--exclude=#{e}" }
      result = @shell.run(['rsync', '-a', '--stats', '--info=progress2', *excludes, "#{src.mount_point}/", "#{dst.mount_point}/"])
      raise Error, "copy failed (rsync exit #{result.status}); nothing was changed in the manifest" unless result.success?
    end

    # --serial wins outright. Otherwise try the hardware serial via smartctl
    # first (a real, stable serial that survives a reformat), falling back to
    # the APFS Volume UUID when smartctl can't reach the drive (no smartctl
    # installed, needs elevated privileges, or - common for external USB
    # enclosures - the bridge chip doesn't pass SMART through at all).
    def resolve_serial(explicit, mount_point, uuid)
      return [explicit, 'the --serial you gave'] if explicit

      if (serial = volume_info.smartctl_serial(mount_point))
        [serial, 'the smartctl hardware serial']
      else
        [uuid, 'the diskutil Volume UUID (smartctl serial unavailable)']
      end
    end

    def status
      print_run_status
      mounted = volume_info.mounted_drives(manifest.drives).to_h { |m| [m.serial_number, m] }
      @out.puts 'Drives:'
      manifest.drives.each do |d|
        m = mounted[d.serial_number]
        usage = if m
                  "#{Jbod::Placement.format_bytes(m.used_bytes)} used, #{Jbod::Placement.format_bytes(m.free_bytes)} free at #{m.mount_point}"
                elsif volume_info.locked?(d.friendly_name)
                  "connected but LOCKED (unlock it: diskutil apfs unlockVolume #{d.friendly_name})"
                else
                  "not mounted (last seen #{d.last_seen_at || 'never'})"
                end
        @out.puts "  #{d.friendly_name.ljust(16)} #{d.serial_number.ljust(38)} #{usage}"
        @out.puts "  #{' ' * 16} SMART #{d.smart_status || 'unchecked'}#{d.smart_detail ? ": #{d.smart_detail}" : ''}"
      end
      retired = manifest.drives(include_retired: true).select(&:retired?)
      retired.each { |d| @out.puts "  #{d.friendly_name.ljust(16)} #{d.serial_number.ljust(38)} retired #{d.retired_at}" }
      @out.puts "\nFolders:"
      names = manifest.drives(include_retired: true).to_h { |d| [d.serial_number, d.friendly_name] }
      manifest.folders.each do |f|
        @out.puts "  #{f.folder_path.ljust(30)} #{names.fetch(f.drive_serial, f.drive_serial).ljust(16)} " \
                  "#{Jbod::Placement.format_bytes(f.size_bytes).rjust(10)}  last synced #{f.last_synced_at || 'never'} " \
                  "#{f.last_sync_status}"
      end
    end

    # A stale lock (its process no longer running) is reported as not running,
    # the same way RunLock itself would reclaim it on the next `sync`.
    def print_run_status
      run = Jbod::RunLock.new(settings[:lock_path]).status
      @out.puts(run ? "Sync running: pid #{run.pid}, started #{run.started_at.strftime('%Y-%m-%d %H:%M:%S %Z')} " \
                      "(#{format_elapsed(@clock.now - run.started_at)} ago)" \
                    : 'No sync currently running.')
      @out.puts
    end

    # "2h 34m", "45m", or "12s".
    def format_elapsed(seconds)
      hours, rem = seconds.to_i.divmod(3600)
      minutes, secs = rem.divmod(60)
      return "#{hours}h #{minutes}m" if hours.positive?
      return "#{minutes}m #{secs}s" if minutes.positive?

      "#{secs}s"
    end

    def history(folder)
      names = manifest.drives(include_retired: true).to_h { |d| [d.serial_number, d.friendly_name] }
      manifest.history(folder).each do |e|
        @out.puts "#{e.recorded_at}  #{e.event.ljust(10)} #{e.folder_path.ljust(30)} -> #{names.fetch(e.drive_serial, e.drive_serial)}  #{e.note}"
      end
    end

    def reassign(args)
      opts = {}
      OptionParser.new { |o| o.on('--note TEXT') { |v| opts[:note] = v } }.parse!(args)
      folder, drive_name = args
      raise Error, "reassign needs FOLDER and DRIVE_NAME\n\n#{USAGE}" unless folder && drive_name

      drive = manifest.drive_by_name(drive_name) or raise Error, "no drive named #{drive_name}"
      manifest.reassign_folder(folder, drive.serial_number, note: opts[:note])
      @out.puts "#{folder} is now recorded on #{drive.friendly_name}. No data was moved."
    end

    def dashboard
      mounted = volume_info.mounted_drives(manifest.drives)
      path = Jbod::Dashboard.new(manifest, grace_days: settings[:grace_days])
                            .write(settings[:dashboard_path], mounted: mounted)
      @out.puts "Dashboard written to #{path}"
    end
  end
end
