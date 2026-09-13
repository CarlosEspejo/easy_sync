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
    end
  end
end
