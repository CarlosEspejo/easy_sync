# frozen_string_literal: true

require 'time'

module EasySync
  module Jbod
    # Reads Backblaze Personal's own local state files, read-only, to say
    # whether each drive's contents have reached Backblaze: the same numbers
    # its menu-bar icon shows. Backblaze backs up *from the drives*, so a
    # drive powered off before its upload finishes leaves that data offsite
    # only on the NAS until the next time it's connected.
    #
    # Files used (all under DATA_DIR, world-readable):
    # - bzvolumes.xml: each volume Backblaze knows, by GUID, with its mount
    #   point (hex-encoded, with a trailing slash).
    # - bzreports/bzstat_remainingbackup.xml: files and bytes still to upload,
    #   per volume GUID.
    # - bzfilelists/<GUID>_*filelist.dat: rewritten each time Backblaze scans
    #   that volume, so its mtime is when it last looked for new files.
    # - bzreports/bzstat_lastbackupcompleted.xml: when a backup pass last
    #   finished.
    # The XML is one self-closing tag per line, so attributes are read with a
    # regex rather than taking on an XML parser dependency.
    class Backblaze
      DATA_DIR = '/Library/Backblaze.bzpkg/bzdata'

      Volume = Struct.new(:guid, :mount_point, :remaining_files, :remaining_bytes, :scanned_at, keyword_init: true)

      # +state+ is :uploading (files left), :waiting (nothing left, but
      # Backblaze hasn't scanned the drive since easy_sync last copied data to
      # it, so the zero is stale), :done, or :unknown (Backblaze doesn't know
      # this volume).
      DriveState = Struct.new(:state, :files, :bytes, :scanned_at, keyword_init: true) do
        def done? = state == :done

        def label
          case state
          when :done then 'up to date'
          when :uploading
            "uploading, #{files.to_s.gsub(/(\d)(?=(\d{3})+\z)/, '\1,')} file#{'s' if files != 1} " \
              "(#{Placement.format_bytes(bytes)}) left"
          when :waiting then 'not scanned since the last sync'
          else 'not in Backblaze'
          end
        end
      end

      # serial => DriveState for +drives+ (Drive structs). A drive not
      # mounted now is looked up at its usual mount point, which is where
      # Backblaze last saw it.
      def drive_states(drives, mounted:, mount_root:, last_copied_at:)
        drives.to_h do |d|
          mount = mounted[d.serial_number]&.mount_point || File.join(mount_root, d.friendly_name)
          [d.serial_number, drive_state(mount, last_copied_at[d.serial_number])]
        end
      end

      attr_reader :last_completed_at

      # nil when Backblaze isn't installed or its state can't be read: callers
      # then show nothing at all about it.
      def self.read(dir = DATA_DIR)
        return nil unless File.file?(File.join(dir, 'bzvolumes.xml'))

        new(dir)
      rescue SystemCallError
        nil
      end

      def initialize(dir)
        @dir = dir
        remaining = tags('bzreports/bzstat_remainingbackup.xml', 'bzvolume').to_h { |a| [a['bzVolumeGuid'], a] }
        @volumes = tags('bzvolumes.xml', 'bzvolume').to_h do |a|
          guid = a['bzVolumeGuid']
          left = remaining[guid] || {}
          mount = [a['mountPointPathHex'].to_s].pack('H*').chomp('/')
          [mount, Volume.new(guid: guid, mount_point: mount, remaining_files: left['pervol_remaining_files_numfiles'].to_i,
                             remaining_bytes: left['pervol_remaining_files_numbytes'].to_i, scanned_at: scanned_at(guid))]
        end
        millis = tags('bzreports/bzstat_lastbackupcompleted.xml', 'lastbackupcompleted').first&.fetch('gmt_millis', nil)
        @last_completed_at = millis && Time.at(millis.to_i / 1000.0).utc
      end

      def volume(mount_point) = @volumes[mount_point.to_s.chomp('/')]

      # +last_copied_at+ is when easy_sync last copied data onto the drive
      # (ISO 8601, or nil if never).
      def drive_state(mount_point, last_copied_at)
        vol = volume(mount_point) or return DriveState.new(state: :unknown)

        state = if vol.remaining_files.positive? then :uploading
                elsif vol.scanned_at.nil? || (last_copied_at && vol.scanned_at < Time.parse(last_copied_at)) then :waiting
                else :done
                end
        DriveState.new(state: state, files: vol.remaining_files, bytes: vol.remaining_bytes, scanned_at: vol.scanned_at)
      end

      private

      def tags(relative, name)
        path = File.join(@dir, relative)
        return [] unless File.file?(path)

        File.read(path).scan(/<#{name}\s([^>]*?)\/?>/).map { |(attrs)| attrs.scan(/(\w+)="([^"]*)"/).to_h }
      end

      def scanned_at(guid)
        list = Dir.glob(File.join(@dir, 'bzfilelists', "#{guid}_*filelist.dat")).first
        list && File.mtime(list).utc
      end
    end
  end
end
