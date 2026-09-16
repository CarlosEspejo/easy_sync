# frozen_string_literal: true

module EasySync
  module Jbod
    # Decides where a brand-new folder goes. Pure logic, no I/O.
    #
    # Rule: the mounted drive with the most free space wins. A folder is never
    # placed on a drive it would not fit on, and existing folders are never
    # moved (that is what makes the JBOD layout browsable by hand).
    module Placement
      class NoMountedDrives < Error; end
      class DoesNotFit < Error; end

      # +candidates+ are MountedDrive structs. +size_bytes+ is the folder size
      # (nil when unknown, in which case only the free-space ordering applies).
      # +reserve_bytes+ is headroom to leave on the drive after placement.
      def self.choose(candidates, size_bytes: nil, reserve_bytes: 0)
        raise NoMountedDrives, 'no registered drives are mounted' if candidates.empty?

        best = candidates.max_by { |c| [c.free_bytes, c.friendly_name.to_s] }
        if size_bytes && (best.free_bytes - reserve_bytes) < size_bytes
          raise DoesNotFit,
                "#{format_bytes(size_bytes)} does not fit on #{best.friendly_name} " \
                "(#{format_bytes(best.free_bytes)} free, #{format_bytes(reserve_bytes)} reserved)"
        end
        best
      end

      # "2gb", "500 MB", 2147483648 -> bytes. Used for config values and CLI flags.
      def self.parse_size(value)
        return value.to_i if value.is_a?(Numeric)

        m = value.to_s.strip.match(/\A([\d.]+)\s*(tb|gb|mb|kb|b)?\z/i) or raise Error, "cannot parse size #{value.inspect} (try 2gb)"
        (m[1].to_f * { nil => 1, 'b' => 1, 'kb' => 1024, 'mb' => 1024**2, 'gb' => 1024**3, 'tb' => 1024**4 }[m[2]&.downcase]).to_i
      end

      UNITS = %w[B KB MB GB TB PB].freeze

      def self.format_bytes(bytes)
        return '—' if bytes.nil?

        value = bytes.to_f
        unit = 0
        while value >= 1024 && unit < UNITS.size - 1
          value /= 1024
          unit += 1
        end
        unit.zero? ? "#{bytes} B" : format('%.1f %s', value, UNITS[unit])
      end

      # "3d 4h", "2h 34m", "45m", or "12s". Shared by `status` and the
      # dashboard so an elapsed/remaining time reads the same everywhere.
      def self.format_duration(seconds)
        days, rem = seconds.to_i.divmod(86_400)
        hours, rem = rem.divmod(3600)
        minutes, secs = rem.divmod(60)
        return "#{days}d #{hours}h" if days.positive?
        return "#{hours}h #{minutes}m" if hours.positive?
        return "#{minutes}m #{secs}s" if minutes.positive?

        "#{secs}s"
      end
    end
  end
end
