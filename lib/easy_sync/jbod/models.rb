# frozen_string_literal: true

require 'time'

module EasySync
  module Jbod
    Drive = Struct.new(:serial_number, :friendly_name, :capacity_bytes, :added_date, :volume_uuid, :model,
                       :last_seen_at, :last_used_bytes, :last_free_bytes,
                       :smart_status, :smart_detail, :smart_checked_at, :power_on_hours, :retired_at,
                       keyword_init: true) do
      def retired? = !retired_at.nil?

      def used_fraction
        return nil if last_used_bytes.nil? || capacity_bytes.to_i.zero?

        last_used_bytes.to_f / capacity_bytes
      end

      # smartctl's Device Model has no separate "vendor" field for ATA/NVMe
      # drives (that's a SCSI/USB-bridge thing); the maker is only ever
      # visible as a token baked into the model string itself, or - for
      # Seagate - not spelled out at all, just implied by the "ST" model
      # prefix every Seagate drive uses.
      BRANDS = {
        'WDC' => 'Western Digital', 'WD' => 'Western Digital', 'TOSHIBA' => 'Toshiba', 'HGST' => 'HGST',
        'SAMSUNG' => 'Samsung', 'HITACHI' => 'Hitachi', 'APPLE' => 'Apple', 'SEAGATE' => 'Seagate',
        'CRUCIAL' => 'Crucial', 'KINGSTON' => 'Kingston', 'INTEL' => 'Intel'
      }.freeze

      def manufacturer
        return nil unless model

        token = model[/\A[A-Za-z]+/]
        return BRANDS[token.upcase] if token && BRANDS.key?(token.upcase)

        'Seagate' if model.match?(/\AST\d/i)
      end

      # model, with the manufacturer spelled out plainly instead of a raw
      # token (or, for Seagate, added - its model numbers don't carry one).
      def branded_model
        return nil unless model
        return model unless manufacturer

        rest = model.sub(/\A(?:WDC|WD|TOSHIBA|HGST|SAMSUNG|HITACHI|APPLE|SEAGATE|CRUCIAL|KINGSTON|INTEL)[\s-]+/i, '')
        "#{manufacturer} #{rest}"
      end

      # SMART's Power_On_Hours counts only time actually spinning/powered,
      # unlike calendar age: a 5-year-old drive that sat on a shelf can show
      # a fraction of the wear of one bought last year and run constantly.
      def runtime_label
        return nil unless power_on_hours

        years = power_on_hours / 24.0 / 365
        return format('%d days (%d hrs)', (power_on_hours / 24.0).round, power_on_hours) if years < 1

        format('%.1f yrs (%d hrs)', years, power_on_hours)
      end
    end

    Folder = Struct.new(:folder_path, :drive_serial, :size_bytes, :assigned_at,
                        :last_synced_at, :last_sync_status, keyword_init: true)

    HistoryEntry = Struct.new(:id, :folder_path, :drive_serial, :event, :recorded_at, :note,
                              keyword_init: true)

    SyncRun = Struct.new(:id, :folder_path, :drive_serial, :started_at, :finished_at, :exit_status,
                         :bytes_transferred, :total_size_bytes, keyword_init: true)

    # A path on a drive that rsync reported as no longer present on the NAS.
    # relative_path is '' (kind 'folder') when the whole folder is gone.
    PendingDeletion = Struct.new(:id, :folder_path, :relative_path, :kind, :first_missing_at, :last_missing_at,
                                 :missing_runs, keyword_init: true) do
      def whole_folder? = kind == 'folder'

      def expires_at(grace_days)
        Time.parse(first_missing_at) + (grace_days * 86_400)
      end

      def expired?(now:, grace_days:, grace_runs:)
        missing_runs >= grace_runs && expires_at(grace_days) <= now
      end
    end

    Deletion = Struct.new(:id, :folder_path, :relative_path, :kind, :drive_serial, :first_missing_at, :deleted_at,
                          keyword_init: true)

    # One row per folder seen on the NAS at the last completed placement
    # pass: placed (assigned to a drive, synced or queued), unplaced (no drive
    # has room, or nothing is mounted) or empty (no real files).
    SourceEntry = Struct.new(:folder_path, :size_bytes, :state, :detail, :seen_at, keyword_init: true) do
      def share = folder_path.split('/').first
    end

    # SMART health as last read from the drive. status is one of
    # 'ok' (self-assessment passed, no bad-sector counters), 'warning' (passed
    # but reallocated/pending/uncorrectable sectors or an NVMe critical flag:
    # the drive is starting to fail), 'failing' (self-assessment FAILED), or
    # 'unknown' (SMART not exposed by the enclosure, smartctl missing, etc.).
    Health = Struct.new(:status, :detail, :source, :power_on_hours, keyword_init: true)

    # A registered drive that is currently mounted, with live usage numbers.
    MountedDrive = Struct.new(:drive, :mount_point, :capacity_bytes, :used_bytes, :free_bytes,
                              keyword_init: true) do
      def serial_number = drive.serial_number
      def friendly_name = drive.friendly_name
    end
  end
end
