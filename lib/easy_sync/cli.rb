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
      Usage: easy_sync [snapshot]
             easy_sync jbod sync [--dry-run]
             easy_sync jbod register-drive MOUNT_POINT --name NAME [--serial SERIAL]
             easy_sync jbod status
             easy_sync jbod history [FOLDER]
             easy_sync jbod reassign FOLDER DRIVE_NAME [--note TEXT]
             easy_sync jbod dashboard
    TEXT

    def initialize(argv, out: $stdout, err: $stderr, config_path: Config.default_path, shell: Shell.new)
      @argv = argv.dup
      @out = out
      @err = err
      @config_path = config_path
      @shell = shell
    end

    def run
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
      when 'dashboard' then dashboard
      else raise Error, "unknown jbod command #{sub.inspect}\n\n#{USAGE}"
      end
    end

    def jbod_sync(args)
      opts = { dry_run: false }
      OptionParser.new { |o| o.on('--dry-run', 'Show rsync commands without running them') { opts[:dry_run] = true } }
                  .parse!(args)
      mirror = Jbod::Mirror.new(shell: @shell, delete: settings.fetch(:delete, true),
                                extra_args: settings.fetch(:rsync_args, []) + (opts[:dry_run] ? ['--dry-run'] : []))
      Jbod::Runner.new(settings, manifest: manifest, volume_info: volume_info, mirror: mirror,
                                 shell: @shell, out: @out).run
    end

    def register_drive(args)
      opts = {}
      OptionParser.new do |o|
        o.on('--name NAME', 'Friendly name, e.g. backup-04-8tb (defaults to the volume name)') { |v| opts[:name] = v }
        o.on('--serial SERIAL', 'Hardware serial (e.g. from smartctl). Defaults to the APFS Volume UUID') { |v| opts[:serial] = v }
      end.parse!(args)
      mount_point = args.first or raise Error, "register-drive needs a mount point\n\n#{USAGE}"
      raise Error, "#{mount_point} is not mounted" unless Dir.exist?(mount_point)

      existing = volume_info.read_marker(mount_point)
      raise Error, "#{mount_point} already carries a marker for #{existing[:serial_number]} (#{existing[:friendly_name]})" if existing

      name = opts[:name] || File.basename(mount_point)
      uuid = volume_info.volume_uuid(mount_point)
      serial = opts[:serial] || uuid or raise Error, 'could not determine a Volume UUID; pass --serial'
      usage = volume_info.usage(mount_point)

      drive = manifest.register_drive(serial_number: serial, friendly_name: name,
                                      capacity_bytes: usage.capacity_bytes, volume_uuid: uuid)
      manifest.update_drive_usage(serial, used_bytes: usage.used_bytes, free_bytes: usage.free_bytes)
      volume_info.write_marker(mount_point, serial_number: serial, friendly_name: name)
      @out.puts "Registered #{drive.friendly_name} (#{drive.serial_number}), " \
                "#{Jbod::Placement.format_bytes(drive.capacity_bytes)} at #{mount_point}"
    end

    def status
      mounted = volume_info.mounted_drives(manifest.drives).to_h { |m| [m.serial_number, m] }
      @out.puts 'Drives:'
      manifest.drives.each do |d|
        m = mounted[d.serial_number]
        usage = m ? "#{Jbod::Placement.format_bytes(m.used_bytes)} used, #{Jbod::Placement.format_bytes(m.free_bytes)} free at #{m.mount_point}" \
                  : "not mounted (last seen #{d.last_seen_at || 'never'})"
        @out.puts "  #{d.friendly_name.ljust(16)} #{d.serial_number.ljust(38)} #{usage}"
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
      path = Jbod::Dashboard.new(manifest, warn_threshold: settings[:warn_threshold])
                            .write(settings[:dashboard_path], mounted: mounted)
      @out.puts "Dashboard written to #{path}"
    end
  end
end
