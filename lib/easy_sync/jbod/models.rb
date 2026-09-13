# frozen_string_literal: true

module EasySync
  module Jbod
    Drive = Struct.new(:serial_number, :friendly_name, :capacity_bytes, :added_date, :volume_uuid,
                       :last_seen_at, :last_used_bytes, :last_free_bytes, keyword_init: true) do
      def used_fraction
        return nil if last_used_bytes.nil? || capacity_bytes.to_i.zero?

        last_used_bytes.to_f / capacity_bytes
      end
    end

    Folder = Struct.new(:folder_path, :drive_serial, :size_bytes, :assigned_at,
                        :last_synced_at, :last_sync_status, keyword_init: true)

    HistoryEntry = Struct.new(:id, :folder_path, :drive_serial, :event, :recorded_at, :note,
                              keyword_init: true)

    SyncRun = Struct.new(:id, :folder_path, :drive_serial, :started_at, :finished_at, :exit_status,
                         :bytes_transferred, :total_size_bytes, keyword_init: true)

    # A registered drive that is currently mounted, with live usage numbers.
    MountedDrive = Struct.new(:drive, :mount_point, :capacity_bytes, :used_bytes, :free_bytes,
                              keyword_init: true) do
      def serial_number = drive.serial_number
      def friendly_name = drive.friendly_name
    end
  end
end
