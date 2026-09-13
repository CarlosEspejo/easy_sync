# frozen_string_literal: true

require 'optparse'
require 'securerandom'

module EasySync
  # Command-line entry point.
  #
  #   easy_sync                       run the incremental snapshot tasks (original behaviour)
  #   easy_sync snapshot              same
  #   easy_sync jbod sync             mirror NAS folders onto the JBOD drives
  #   easy_sync jbod register-drive   register a mounted drive
  #   easy_sync jbod status           print drives and folders
  #   easy_sync jbod history [FOLDER] print placement history
  #   easy_sync jbod reassign FOLDER DRIVE   record a manual move (no data is moved)
  #   easy_sync jbod dashboard        regenerate the HTML report only
  class CLI
    USAGE = <<~TEXT
      Usage: easy_sync [--config PATH] [snapshot]
             easy_sync [--config PATH] jbod sync [--dry-run] [--no-purge] [--no-keep-awake]
             easy_sync jbod register-drive MOUNT_POINT --name NAME [--serial SERIAL]
             easy_sync jbod status
             easy_sync jbod history [FOLDER]
             easy_sync jbod reassign FOLDER DRIVE_NAME [--note TEXT]
             easy_sync jbod pending
             easy_sync jbod dashboard

      --config PATH overrides the config file (default ~/.easy_syncrc.yml);
      the EASY_SYNC_CONFIG environment variable does the same.
    TEXT

    def initialize(argv, out: $stdout, err: $stderr, config_path: nil, shell: Shell.new, env: ENV,
                   keep_awake: Jbod::KeepAwake.new)
      @argv = argv.dup
      @out = out
      @err = err
      @shell = shell
      @keep_awake = keep_awake
      @config_path = config_path || env['EASY_SYNC_CONFIG'] || Config.default_path
    end

    def run
      parse_global_options!
      command = @argv.shift
      case command
      when nil, 'snapshot' then SyncRunner.new(config_path: @config_path, shell: @shell, out: @out, err: @err).run
      when 'jbod' then jbod(@argv.shift, @argv)
      when '-h', '--help', 'help' then @out.puts USAGE
      else
        @err.puts "Unknown command: #{command}\n\n#{USAGE}"
        return 1
      end
      0
    rescue Error, OptionParser::ParseError => e
      @err.puts "error: #{e.message}"
      1
    end

    private

    # Global options come before the command: `easy_sync --config x jbod sync`.
    # Only --config is global, so this is a small hand parser rather than an
    # OptionParser that would also swallow the subcommands' own flags.
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
      @config ||= Config.load(@config_path).first
    end

    def settings = config.jbod

    def manifest
      @manifest ||= Jbod::Manifest.open(settings[:manifest_path])
    end

    def volume_info
      @volume_info ||= Jbod::VolumeInfo.new(mount_root: settings[:mount_root], shell: @shell)
    end

    def jbod(sub, args)
      case sub
      when 'sync' then jbod_sync(args)
      when 'register-drive' then register_drive(args)
      when 'status' then status
      when 'history' then history(args.first)
      when 'reassign' then reassign(args)
      when 'pending' then pending
      when 'dashboard' then dashboard
      else raise Error, "unknown jbod command #{sub.inspect}\n\n#{USAGE}"
      end
    end

    def jbod_sync(args)
      opts = { dry_run: false, purge: nil, keep_awake: settings.fetch(:keep_awake, true) }
      OptionParser.new do |o|
        o.on('--dry-run', 'Show what rsync and the purge would do without changing anything') { opts[:dry_run] = true }
        o.on('--no-purge', 'Sync but do not delete expired files from the drives') { opts[:purge] = false }
        o.on('--no-keep-awake', 'Let the Mac sleep during this run (default: caffeinate keeps it awake)') { opts[:keep_awake] = false }
      end.parse!(args)
      version = Jbod::Mirror.check_version!(@shell)
      @out.puts "Using rsync #{version}#{' (dry run)' if opts[:dry_run]}"
      Jbod::RunLock.new(settings[:lock_path]).acquire do
        @out.puts 'Keeping the Mac awake for this run (caffeinate).' if opts[:keep_awake] && @keep_awake.start
        Jbod::Runner.new(settings, manifest: manifest, volume_info: volume_info, shell: @shell, out: @out,
                                   dry_run: opts[:dry_run], purge: opts[:purge]).run
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

    # --serial wins outright. Otherwise try the hardware serial via smartctl
    # first (a real, stable serial that survives a reformat), falling back to
    # the APFS Volume UUID smartctl can't reach the drive (no smartctl
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
      @out.puts "\nFolders:"
      names = manifest.drives.to_h { |d| [d.serial_number, d.friendly_name] }
      manifest.folders.each do |f|
        @out.puts "  #{f.folder_path.ljust(30)} #{names.fetch(f.drive_serial, f.drive_serial).ljust(16)} " \
                  "#{Jbod::Placement.format_bytes(f.size_bytes).rjust(10)}  last synced #{f.last_synced_at || 'never'} " \
                  "#{f.last_sync_status}"
      end
    end

    def history(folder)
      names = manifest.drives.to_h { |d| [d.serial_number, d.friendly_name] }
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
