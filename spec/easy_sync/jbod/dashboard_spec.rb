# frozen_string_literal: true

RSpec.describe EasySync::Jbod::Dashboard do
  let(:clock) { double('clock', now: Time.utc(2026, 9, 13, 12, 0, 0)) }
  let(:manifest) { memory_manifest(clock: clock) }
  let(:drives) { register_fleet(manifest).to_h { |d| [d.friendly_name, d] } }
  let(:dashboard) { described_class.new(manifest, warn_threshold: 0.85, clock: clock) }

  before do
    drives
    manifest.assign_folder('Photos', 'SN-backup-04-8tb', size_bytes: 6 * TB)
    manifest.record_sync(folder_path: 'Photos', drive_serial: 'SN-backup-04-8tb', started_at: '2026-09-13T11:00:00Z',
                         finished_at: '2026-09-13T11:30:00Z', exit_status: 0, bytes_transferred: 10, total_size_bytes: 6 * TB)
    manifest.update_drive_usage('SN-backup-01-3tb', used_bytes: 1 * TB, free_bytes: 2 * TB)
  end

  it 'renders every drive, folder, history row, and sync run' do
    html = dashboard.render(mounted: [mounted(drives['backup-04-8tb'], free: 1 * TB, used: 7 * TB)])
    expect(html).to include('<title>Backup status</title>')
    drives.each_key { |name| expect(html).to include(name) }
    expect(html).to include('Photos', 'assigned', '6.0 TB', 'ok')
    expect(html).to include('7 drives, 1 mounted', '1 folders tracked')
  end

  it 'flags drives over the warning threshold and marks critical above 95%' do
    html = dashboard.render(mounted: [
      mounted(drives['backup-04-8tb'], free: 1 * TB, used: 7 * TB),
      mounted(drives['backup-05-8tb'], free: 100, used: 8 * TB - 100),
      mounted(drives['backup-06-8tb'], free: 4 * TB, used: 4 * TB)
    ])
    expect(html).to match(/class="tile warning"[\s\S]*?backup-04-8tb/)
    expect(html).to match(/class="tile critical"[\s\S]*?backup-05-8tb/)
    expect(html).to match(/class="tile ok"[\s\S]*?backup-06-8tb/)
    expect(html).to include('<strong>backup-04-8tb</strong> is 88% full')
  end

  it 'shows last-known numbers for drives that are not mounted' do
    html = dashboard.render(mounted: [])
    expect(html).to include('not mounted')
    expect(html).to match(/backup-01-3tb[\s\S]*?33% used[\s\S]*?1\.0 TB used · 2\.0 TB free · 3\.0 TB total/)
    expect(html).to include('has never been seen mounted')
  end

  it 'escapes HTML in names' do
    manifest.assign_folder('<script>alert(1)</script>', 'SN-backup-01-3tb')
    html = dashboard.render
    expect(html).not_to include('<script>alert(1)')
    expect(html).to include('&lt;script&gt;')
  end

  it 'writes the file, creating parent directories' do
    path = File.join(temp_dir, 'reports', 'dashboard.html')
    expect(dashboard.write(path)).to eq(path)
    expect(File.read(path)).to start_with('<!doctype html>')
  end
end
