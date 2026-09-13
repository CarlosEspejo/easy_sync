# frozen_string_literal: true

require 'optparse'

module EasySync
  # Command-line entry point. `easy_sync jbod <command>` (the 1.x spelling)
  # is accepted as an alias for `easy_sync <command>`.
  class CLI
    USAGE = <<~TEXT
      Usage: easy_sync [--config PATH] <command>

        sync [--dry-run] [--no-purge] [--no-keep-awake]   mirror the shares onto the drives
        register-drive MOUNT_POINT [--name NAME] [--serial SERIAL]
        replace-drive OLD_NAME [--to NEW_NAME] [--copy]      retire a drive; move its folders to NEW (or let the next sync re-place them)
        status                                             drives and folders, in the terminal
        history [FOLDER]                                   where has a folder lived?
        reassign FOLDER DRIVE_NAME [--note TEXT]           record a move you made by hand (moves no data)
        pending                                            deletion candidates and their expiry dates
        plan [--largest-drive SIZE]                        split or whole? measured recommendation per share
        dashboard                                          regenerate the HTML report only

      --config PATH overrides the config file (default ~/.easy_sync/config.yml);
      the EASY_SYNC_CONFIG environment variable does the same.
    TEXT

    COMMANDS = %w[sync register-drive status history reassign pending plan dashboard].freeze

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
      command = @argv.shift if command == 'jbod'   # 1.x alias
      case command
      when nil, '-h', '--help', 'help' then @out.puts USAGE
      when 'sync' then sync(@argv)
      when 'register-drive' then register_drive(@argv)
      when 'replace-drive' then replace_drive(@argv)
      when 'status' then status
      when 'history' then history(@argv.first)
      when 'reassign' then reassign(@argv)
      when 'pending' then pending
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
        @err.puts "Moved #{Config::LEGACY_PATH} to #{@config_path}" if status == :migrated
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

    # Measures every configured share and says whether to split it.
    def plan(args)
      opts = {}
      OptionParser.new do |o|
        o.on('--largest-drive SIZE', 'Capacity of the biggest drive you will register, e.g. 8tb (default: from the manifest)') do |v|
          opts[:largest] = parse_size(v)
        end
      end.parse!(args)
      largest = opts[:largest] || manifest.drives.map(&:capacity_bytes).max
      @out.puts(largest ? "Judging against the largest drive: #{Jbod::Placement.format_bytes(largest)}" \
                        : 'No drives registered yet; pass --largest-drive 8tb for recommendations')
      rows = Jbod::Planner.new(settings, shell: @shell, largest_drive_bytes: largest).rows
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
      @out.puts "\nPaste into :sources: :"
      rows.each do |r|
        split = r.recommend_split.nil? ? r.source.split : r.recommend_split
        @out.puts "  - :path: \"#{r.source.path}\"\n    :split: #{split}"
      end
    end

    def parse_size(text)
      m = text.to_s.strip.match(/\A([\d.]+)\s*(tb|gb|mb|kb|b)?\z/i) or raise Error, "cannot parse size #{text.inspect} (try 8tb)"
      (m[1].to_f * { nil => 1, 'b' => 1, 'kb' => 1024, 'mb' => 1024**2, 'gb' => 1024**3, 'tb' => 1024**4 }[m[2]&.downcase]).to_i
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
