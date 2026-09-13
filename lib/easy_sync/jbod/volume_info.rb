# frozen_string_literal: true

require 'json'

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

      def read_marker(mount_point)
        path = File.join(mount_point, MARKER_FILE)
        return nil unless File.file?(path)

        data = JSON.parse(File.read(path), symbolize_names: true)
        return nil unless data[:serial_number]

        data.slice(:serial_number, :friendly_name, :registered_at)
      rescue JSON::ParserError
        nil
      end

      def write_marker(mount_point, serial_number:, friendly_name:, registered_at: Time.now.utc.iso8601)
        raise NotMounted, "#{mount_point} is not a directory" unless Dir.exist?(mount_point)

        path = File.join(mount_point, MARKER_FILE)
        File.write(path, JSON.pretty_generate(serial_number: serial_number, friendly_name: friendly_name,
                                              registered_at: registered_at))
        path
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
    end
  end
end
