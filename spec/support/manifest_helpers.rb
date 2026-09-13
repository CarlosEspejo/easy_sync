# frozen_string_literal: true

TB = 1024**4

module ManifestHelpers
  def memory_manifest(clock: Time)
    EasySync::Jbod::Manifest.new(SQLite3::Database.new(':memory:'), clock: clock)
  end

  # Registers the seven drives from the naming convention with plausible serials.
  def register_fleet(manifest)
    {
      'backup-01-3tb' => 3, 'backup-02-6tb' => 6, 'backup-03-6tb' => 6, 'backup-04-8tb' => 8,
      'backup-05-8tb' => 8, 'backup-06-8tb' => 8, 'backup-07-8tb' => 8
    }.map do |name, tb|
      manifest.register_drive(serial_number: "SN-#{name}", friendly_name: name, capacity_bytes: tb * TB)
    end
  end

  def mounted(drive, free:, used: nil, mount_point: "/Volumes/#{drive.friendly_name}")
    used ||= drive.capacity_bytes - free
    EasySync::Jbod::MountedDrive.new(drive: drive, mount_point: mount_point, capacity_bytes: drive.capacity_bytes,
                                     used_bytes: used, free_bytes: free)
  end
end

RSpec.configure { |c| c.include ManifestHelpers }
