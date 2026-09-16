# frozen_string_literal: true

RSpec.describe EasySync::Jbod::SyncEta do
  let(:manifest) { memory_manifest }
  let(:started) { Time.utc(2026, 9, 15, 8, 0, 0) }

  before { manifest.register_drive(serial_number: 'S1', friendly_name: 'backup-01-3tb', capacity_bytes: 3 * TB) }

  it 'says it is waiting when nothing has finished yet this run' do
    manifest.assign_folder('Photos', 'S1', size_bytes: 10 * GB)
    expect(described_class.for(manifest, started).status).to eq(:waiting_for_first_folder)
  end

  it 'combines the observed transfer rate and verify time into one estimate' do
    manifest.assign_folder('Movies/A', 'S1', size_bytes: 100 * GB)   # never synced, remains
    manifest.assign_folder('Movies/B', 'S1', size_bytes: 50 * GB)
    manifest.record_sync(folder_path: 'Movies/B', drive_serial: 'S1', started_at: '2026-01-01T00:00:00Z',
                         finished_at: '2026-01-01T00:00:01Z', exit_status: 0, bytes_transferred: 50 * GB, total_size_bytes: 50 * GB)
    manifest.assign_folder('Movies/C', 'S1', size_bytes: 200 * GB)
    # a real transfer this run: 20 GB in 20s = 1 GB/s
    manifest.record_sync(folder_path: 'Movies/C', drive_serial: 'S1', started_at: '2026-09-15T08:00:10Z',
                         finished_at: '2026-09-15T08:00:30Z', exit_status: 0, bytes_transferred: 20 * GB, total_size_bytes: 200 * GB)
    manifest.assign_folder('Movies/D', 'S1', size_bytes: 10 * GB)
    # a verify-only run this run: 2s, nothing transferred
    manifest.record_sync(folder_path: 'Movies/D', drive_serial: 'S1', started_at: '2026-09-15T08:00:31Z',
                         finished_at: '2026-09-15T08:00:33Z', exit_status: 0, bytes_transferred: 0, total_size_bytes: 10 * GB)

    e = described_class.for(manifest, started)
    # never-synced remaining: Movies/A = 1, at 1 GB/s that's 100s
    # to re-verify: Movies/B (synced before this run) = 1, at the observed 2s (Movies/D's verify)
    expect(e).to have_attributes(status: :estimate, never_synced_count: 1, to_reverify: 1, seconds: 102.0)
  end

  it 'says it is waiting for a first real transfer when only verifies have finished so far this run' do
    manifest.assign_folder('Movies/Y', 'S1', size_bytes: 50 * GB)
    manifest.record_sync(folder_path: 'Movies/Y', drive_serial: 'S1', started_at: '2020-01-01T00:00:00Z',
                         finished_at: '2020-01-01T00:00:01Z', exit_status: 0, bytes_transferred: 50 * GB, total_size_bytes: 50 * GB)
    manifest.record_sync(folder_path: 'Movies/Y', drive_serial: 'S1', started_at: '2026-09-15T08:00:05Z',
                         finished_at: '2026-09-15T08:00:06Z', exit_status: 0, bytes_transferred: 0, total_size_bytes: 50 * GB)
    manifest.assign_folder('Movies/Z', 'S1', size_bytes: 0)

    e = described_class.for(manifest, started)
    expect(e).to have_attributes(status: :waiting_for_first_transfer, never_synced_count: 1, never_synced_bytes: 0)
  end

  it 'is nil once every folder has been touched this run' do
    manifest.assign_folder('Photos', 'S1', size_bytes: 10 * GB)
    manifest.record_sync(folder_path: 'Photos', drive_serial: 'S1', started_at: '2026-09-15T08:00:01Z',
                         finished_at: '2026-09-15T08:00:05Z', exit_status: 0, bytes_transferred: 10 * GB, total_size_bytes: 10 * GB)

    expect(described_class.for(manifest, started)).to be_nil
  end
end
