# frozen_string_literal: true

require 'json'
require 'fileutils'

module EasySync
  module Jbod
    # Everything that touches real volumes lives here so it can be faked in tests.
    #
    # Drive identity does not rely on the mount path. At registration a marker
    # file is written to the root of the volume; on every run the mount root is
    # scanned for markers and each registered drive is matched by the serial
    # number inside its marker. A volume that carries no marker, or a marker for
    # a serial the manifest does not know, is never written to.
    class VolumeInfo
      class NotMounted < Error; end

      Usage = Struct.new(:capacity_bytes, :used_bytes, :free_bytes, keyword_init: true)

      attr_reader :mount_root

      def initialize(mount_root: '/Volumes', shell: Shell.new)
        @mount_root = mount_root
        @shell = shell
      end

      # Returns MountedDrive structs for every registered drive whose marker is
      # found under +mount_root+. Drives are matched by serial number, never by
      # volume name.
      def mounted_drives(registered)
        by_serial = registered.to_h { |d| [d.serial_number, d] }
        markers.filter_map do |marker|
          drive = by_serial[marker[:serial_number]] or next
          usage = usage(marker[:mount_point])
          MountedDrive.new(drive: drive, mount_point: marker[:mount_point],
                           capacity_bytes: usage.capacity_bytes, used_bytes: usage.used_bytes,
                           free_bytes: usage.free_bytes)
        end
      end

      # All markers found under the mount root: [{serial_number:, friendly_name:, mount_point:}]
      def markers
        return [] unless Dir.exist?(mount_root)

        Dir.children(mount_root).sort.filter_map do |name|
          mount_point = File.join(mount_root, name)
          marker = read_marker(mount_point)
          marker && marker.merge(mount_point: mount_point)
        end
      end

      # Reads <drive>/.easy_sync/drive.json, or the pre-folder marker at the
      # drive root (moved into the folder by #copy_state on the next sync).
      def read_marker(mount_point)
        path = [File.join(mount_point, MARKER_FILE), File.join(mount_point, LEGACY_MARKER_FILE)].find { |p| File.file?(p) }
        return nil unless path

        data = JSON.parse(File.read(path), symbolize_names: true)
        return nil unless data[:serial_number]

        data.slice(:serial_number, :friendly_name, :registered_at)
      rescue JSON::ParserError
        nil
      end

      def write_marker(mount_point, serial_number:, friendly_name:, registered_at: Time.now.utc.iso8601)
        raise NotMounted, "#{mount_point} is not a directory" unless Dir.exist?(mount_point)

        path = File.join(mount_point, MARKER_FILE)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(serial_number: serial_number, friendly_name: friendly_name,
                                              registered_at: registered_at))
        path
      end

      # Refreshes <drive>/.easy_sync/ on one mounted drive: moves a legacy
      # root marker into the folder, and drops in a consistent copy of the
      # manifest (via SQLite's online backup API) and of the config file.
      def copy_state(mount_point, manifest:, config_path: nil)
        dir = File.join(mount_point, DRIVE_DIR)
        FileUtils.mkdir_p(dir)
        legacy = File.join(mount_point, LEGACY_MARKER_FILE)
        FileUtils.mv(legacy, File.join(mount_point, MARKER_FILE)) if File.file?(legacy) && !File.file?(File.join(mount_point, MARKER_FILE))
        manifest.backup_to(File.join(dir, 'manifest.sqlite3'))
        FileUtils.cp(config_path, File.join(dir, 'config.yml')) if config_path && File.file?(config_path)
        File.write(File.join(dir, 'README.txt'), <<~TXT)
          This folder is maintained by easy_sync (https://github.com/CarlosEspejo/easy_sync).
          drive.json        identifies this drive to the tool; do not edit or delete it.
          manifest.sqlite3  a copy of the manifest (which folder lives on which drive, and the
                            deletion history) as of the last sync. Any one drive can rebuild the map.
          config.yml        a copy of the configuration used for that sync.
        TXT
        dir
      end

      # Capacity/used/free in bytes, from `df -kP`.
      def usage(mount_point)
        result = @shell.capture(['df', '-kP', mount_point])
        raise NotMounted, "df failed for #{mount_point}: #{result.output}" unless result.success?

        fields = result.output.lines.last.to_s.split
        capacity, used, free = fields[1, 3].map { |kb| Integer(kb) * 1024 }
        Usage.new(capacity_bytes: capacity, used_bytes: used, free_bytes: free)
      rescue ArgumentError, TypeError
        raise NotMounted, "could not parse df output for #{mount_point}: #{result&.output}"
      end

      # APFS Volume UUID from `diskutil info`, or nil when unavailable (non-macOS).
      def volume_uuid(mount_point)
        result = @shell.capture(['diskutil', 'info', mount_point])
        return nil unless result.success?

        result.output[/Volume UUID:\s*([0-9A-Fa-f-]+)/, 1]
      rescue Errno::ENOENT
        nil
      end

      # The hardware serial from smartctl, or nil when it can't be determined:
      # smartctl isn't installed, the drive's USB bridge doesn't pass SMART
      # through (common for external enclosures), or the volume's physical disk
      # can't be resolved. Deliberately ignores the process exit status and
      # looks only for a "Serial Number:" line in the output, because smartctl
      # reports "not supported" failures with exit 0 for some device classes
      # and a nonzero exit for others.
      def smartctl_serial(mount_point)
        disk = physical_disk_for(mount_point) or return nil
        @shell.capture(['smartctl', '-a', "/dev/#{disk}"]).output[/^Serial Number:\s*(\S+)/m, 1]
      rescue Errno::ENOENT
        nil
      end

      # SMART health for the drive under +mount_point+. Tries smartctl on the
      # physical disk (plainly, then through a SAT USB bridge), and when that
      # yields nothing falls back to the one-word SMART Status that
      # `diskutil info` reports. Never raises: an enclosure that hides SMART
      # is reported as 'unknown' with the reason, not as an error.
      def smart_health(mount_point)
        disk = physical_disk_for(mount_point)
        if disk
          [[], ['-d', 'sat']].each do |extra|
            out = @shell.capture(['smartctl', *extra, '-a', "/dev/#{disk}"]).output
            health = self.class.parse_smartctl(out)
            return health if health
          end
        end
        diskutil_health(mount_point)
      rescue Errno::ENOENT
        diskutil_health(mount_point)
      end

      # Parses `smartctl -a` for both ATA and NVMe drives. Returns nil when the
      # output carries no self-assessment line (device not supported, needs
      # sudo, wrong -d type...), so the caller can try the next source.
      def self.parse_smartctl(out)
        verdict = out[/overall-health self-assessment test result:\s*(\w+)/, 1] or return nil
        counters = {}
        out.scan(/^\s*\d+\s+(Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|Reallocated_Event_Count)\s+\S+\s+\d+\s+\d+\s+\d+\s+\S+\s+\S+\s+\S+\s+(\d+)/) do |name, raw|
          counters[name] = raw.to_i
        end
        critical = out[/^Critical Warning:\s*(0x[0-9a-fA-F]+)/, 1]
        media_errors = out[/^Media and Data Integrity Errors:\s*(\d+)/, 1]&.to_i
        pct_used = out[/^Percentage Used:\s*(\d+)%/, 1]
        temp = out[/^\s*\d+\s+Temperature_Celsius\s+\S+\s+\d+\s+\d+\s+\d+\s+\S+\s+\S+\s+\S+\s+(\d+)/, 1] ||
               out[/^Temperature:\s*(\d+)\s*Celsius/, 1]

        bad = counters.values_at('Reallocated_Sector_Ct', 'Current_Pending_Sector', 'Offline_Uncorrectable').compact.sum
        bad += media_errors.to_i
        bad += 1 if critical && critical.hex != 0

        status = if verdict.casecmp?('PASSED') then bad.positive? ? 'warning' : 'ok'
                 else 'failing'
                 end
        parts = [verdict.upcase]
        parts << "reallocated #{counters['Reallocated_Sector_Ct']}" if counters.key?('Reallocated_Sector_Ct')
        parts << "pending #{counters['Current_Pending_Sector']}" if counters.key?('Current_Pending_Sector')
        parts << "uncorrectable #{counters['Offline_Uncorrectable']}" if counters.key?('Offline_Uncorrectable')
        parts << "critical warning #{critical}" if critical && critical.hex != 0
        parts << "media errors #{media_errors}" if media_errors
        parts << "#{pct_used}% of rated life used" if pct_used
        parts << "#{temp}°C" if temp
        Health.new(status: status, detail: parts.join(' · '), source: 'smartctl')
      end

      def diskutil_health(mount_point)
        result = @shell.capture(['diskutil', 'info', mount_point])
        word = result.success? ? result.output[/SMART Status:\s*(.+)$/, 1]&.strip : nil
        case word
        when 'Verified' then Health.new(status: 'ok', detail: 'diskutil reports Verified (no counters available)', source: 'diskutil')
        when 'Failing' then Health.new(status: 'failing', detail: 'diskutil reports Failing', source: 'diskutil')
        else Health.new(status: 'unknown', detail: 'SMART not exposed by this enclosure (smartctl and diskutil both blind)',
                        source: 'none')
        end
      rescue Errno::ENOENT
        Health.new(status: 'unknown', detail: 'diskutil/smartctl not available on this system', source: 'none')
      end

      # Resolves a mounted volume to the physical (or physical store) disk
      # underneath it: mount point -> APFS container ("Part of Whole") ->
      # container's physical store. Returns nil if any step can't be read.
      def physical_disk_for(mount_point)
        info = @shell.capture(['diskutil', 'info', mount_point])
        return nil unless info.success?

        container = info.output[/Part of Whole:\s*(disk\d+)/, 1] or return nil
        container_info = @shell.capture(['diskutil', 'info', container])
        return nil unless container_info.success?

        container_info.output[/APFS Physical Store:\s*(disk\d+s\d+)/, 1] || container
      end

      # Best-effort FileVault lock state for a registered drive that isn't
      # currently mounted, looked up by name in `diskutil apfs list` (a locked
      # volume has no mount point but still appears there by name). Returns
      # true (locked), false (present and unlocked, or not encrypted), or nil
      # when the drive can't be found there at all (unplugged, or diskutil
      # failed) - macOS only.
      def locked?(friendly_name)
        result = @shell.capture(['diskutil', 'apfs', 'list'])
        return nil unless result.success?

        match = apfs_volumes(result.output).find { |v| v[:name].casecmp?(friendly_name) }
        match && match[:lock_state] == 'Locked'
      rescue Errno::ENOENT
        nil
      end

      # Parses `diskutil apfs list` into [{name:, lock_state:}, ...]. lock_state
      # is "Locked", "Unlocked", or nil (not FileVault-encrypted). The Name and
      # FileVault lines belong to the same volume block but are a few lines
      # apart, so this pairs each Name with the next FileVault line after it.
      def apfs_volumes(output)
        volumes = []
        name = nil
        output.each_line do |line|
          if (m = line.match(/^\s*Name:\s*(.+?)\s*\(Case-insensitive\)\s*$/))
            name = m[1]
          elsif name && (m = line.match(/^\s*FileVault:\s*(?:No|Yes \((Locked|Unlocked)\))/))
            volumes << { name: name, lock_state: m[1] }
            name = nil
          end
        end
        volumes
      end
    end
  end
end
