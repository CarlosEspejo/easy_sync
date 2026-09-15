# frozen_string_literal: true

RSpec.describe EasySync::Jbod::Dashboard do
  let(:clock) { double('clock', now: Time.utc(2026, 9, 13, 12, 0, 0)) }
  let(:manifest) { memory_manifest(clock: clock) }
  let(:drives) { register_fleet(manifest).to_h { |d| [d.friendly_name, d] } }
  let(:dashboard) { described_class.new(manifest, clock: clock) }

  before do
    drives
    manifest.assign_folder('Photos', 'SN-backup-04-8tb', size_bytes: 6 * TB)
    manifest.record_sync(folder_path: 'Photos', drive_serial: 'SN-backup-04-8tb', started_at: '2026-09-13T11:00:00Z',
                         finished_at: '2026-09-13T11:30:00Z', exit_status: 0, bytes_transferred: 10, total_size_bytes: 6 * TB)
    manifest.update_drive_usage('SN-backup-01-3tb', used_bytes: 1 * TB, free_bytes: 2 * TB)
  end

  it 'renders every drive, folder, history row, and sync run' do
    html = dashboard.render(mounted: [mounted(drives['backup-04-8tb'], free: 1 * TB, used: 7 * TB)])
    expect(html).to include('<title>Easy Sync Backup Status</title>')
    drives.each_key { |name| expect(html).to include(name) }
    expect(html).to include('Photos', 'assigned', '6.0 TB', 'ok')
    expect(html).to include('7 drives, 1 mounted', '1 folders tracked')
  end

  it 'shows total capacity and free space across all drives, live where mounted, last-known otherwise' do
    html = dashboard.render(mounted: [mounted(drives['backup-04-8tb'], free: 1 * TB, used: 7 * TB)])
    # capacity: registered 3+6+6+8+8+8+8 = 47 TB, regardless of mount state
    # free: backup-04's live 1 TB + backup-01's last-known 2 TB (from the outer before) = 3 TB
    expect(html).to match(%r{<p class="capacity"><strong>47\.0 TB</strong> total capacity ·\s*<strong>3\.0 TB</strong> free right now</p>})
  end

  it 'omits the capacity line when no drives are registered' do
    empty_manifest = memory_manifest(clock: clock)
    html = described_class.new(empty_manifest, clock: clock).render
    expect(html).not_to include('class="capacity"')
  end

  it 'colours tiles by SMART health and never by fullness' do
    manifest.update_drive_health('SN-backup-04-8tb', status: 'ok', detail: 'PASSED · reallocated 0 · 36°C')
    manifest.update_drive_health('SN-backup-05-8tb', status: 'warning', detail: 'PASSED · reallocated 12 · pending 3')
    manifest.update_drive_health('SN-backup-06-8tb', status: 'failing', detail: 'FAILED')
    html = dashboard.render(mounted: [
      mounted(drives['backup-04-8tb'], free: 100, used: 8 * TB - 100),   # 100% full, healthy
      mounted(drives['backup-05-8tb'], free: 4 * TB, used: 4 * TB),
      mounted(drives['backup-06-8tb'], free: 7 * TB, used: 1 * TB),
      mounted(drives['backup-07-8tb'], free: 4 * TB, used: 4 * TB)       # never checked
    ])
    expect(html).to match(/class="tile ok"[\s\S]*?backup-04-8tb[\s\S]*?used · 100%[\s\S]*?SMART ok · 36°C</)
    expect(html).to match(/class="tile warning"[\s\S]*?backup-05-8tb[\s\S]*?SMART: starting to fail/)
    expect(html).to match(/class="tile critical"[\s\S]*?backup-06-8tb[\s\S]*?SMART: FAILING/)
    expect(html).to match(/class="tile unknown"[\s\S]*?backup-07-8tb[\s\S]*?SMART n\/a/)
    expect(html).to include('<strong>backup-05-8tb</strong> is starting to fail', 'reallocated 12 · pending 3')
    expect(html).to include('<small>PASSED · reallocated 12 · pending 3</small>')   # counters shown only when they matter
    expect(html).to include('easy_sync replace-drive backup-05-8tb --to NEW_NAME --copy')
    expect(html).not_to include('jbod reassign')
    expect(html).to include('<strong>backup-06-8tb</strong> is FAILING')
    expect(html).not_to include('is 100% full')
    expect(html).to include('drive colours show SMART health, not fullness')
  end

  it 'shows last-known numbers for drives that are not mounted, without alarm' do
    html = dashboard.render(mounted: [])
    expect(html).to include('not mounted')
    expect(html).to match(%r{backup-01-3tb[\s\S]*?2\.0 TB <span class="unit">free</span>[\s\S]*?1\.0 TB of 3\.0 TB used · 33%})
    expect(html).not_to include('class="alert')
  end

  it 'keeps a healthy mounted tile quiet: no mounted badge, no mount path, no zero counters' do
    manifest.update_drive_health('SN-backup-04-8tb', status: 'ok', detail: 'PASSED · reallocated 0 · pending 0 · 36°C')
    html = dashboard.render(mounted: [mounted(drives['backup-04-8tb'], free: 1 * TB)])
    expect(html).not_to include('class="badge ok"')
    expect(html).not_to include('at /Volumes/backup-04-8tb')
    expect(html).to include('title="PASSED · reallocated 0 · pending 0 · 36°C">SMART ok · 36°C</div>')
    expect(html).not_to include('<small>PASSED · reallocated 0')
  end

  it 'shows the mount path only when macOS mounted the drive under a different name' do
    html = dashboard.render(mounted: [mounted(drives['backup-04-8tb'], free: 1 * TB, mount_point: '/Volumes/backup-04-8tb 1')])
    expect(html).to include('at /Volumes/backup-04-8tb 1')
  end

  it 'says "1 folder", not "1 folders", when a single folder is not backed up' do
    manifest.replace_source_inventory([{ folder_path: 'synology', size_bytes: 2 * TB, state: 'unplaced', detail: 'no drive has room' }])
    html = dashboard.render(mounted: [])
    expect(html).to include('1 folder · 2.0 TB · no drive has room')
  end

  it 'shows the drive manufacturer and model next to the serial when known, and nothing extra when not' do
    manifest.register_drive(serial_number: 'SN-with-model', friendly_name: 'backup-08-8tb', capacity_bytes: 8 * TB,
                            model: 'WDC WD80EFZZ-68BTXN0')
    html = dashboard.render(mounted: [])
    expect(html).to match(%r{<div class="serial">SN-with-model · Western Digital WD80EFZZ-68BTXN0</div>})
    expect(html).to match(%r{<div class="serial">SN-backup-01-3tb</div>})
  end

  it 'groups folders by share, collapses big shares, and surfaces problem rows at the top' do
    60.times { |i| manifest.assign_folder("movies/Film #{i}", 'SN-backup-05-8tb', size_bytes: TB / 100) }
    manifest.assign_folder('tv/Show A', 'SN-backup-05-8tb', size_bytes: TB / 10)
    manifest.mark_folder_status('movies/Film 7', 'drive_full')
    html = dashboard.render(mounted: [mounted(drives['backup-05-8tb'], free: 1 * TB)])

    expect(html).to match(/<details class="share attention" open>[\s\S]*?Needs attention[\s\S]*?movies\/Film 7[\s\S]*?drive full/)
    expect(html).to include('1 folder not in a good state')        # the 59 never-synced films are pending work, not problems
    expect(html).to include('60 folders · 614.4 GB · 59 not yet synced', '(60 not yet synced)')
    expect(html).to match(/<details class="share">\s*<summary>\s*<span class="share-name">movies<\/span>\s*<span class="share-meta">60 folders · 614\.4 GB/)
    expect(html).to include('1 needs attention')
    # every share starts collapsed; only Needs attention starts open
    expect(html).not_to include('<details class="share" open>')
    expect(html).to match(/<details class="share">\s*<summary>\s*<span class="share-name">Photos/)
    expect(html).to match(/<details class="share">\s*<summary>\s*<span class="share-name">tv/)
    # drive tile shows per-share totals rather than sixty list items
    expect(html).to match(/<ul class="shares">[\s\S]*?movies · 60 folders<\/span><span>614\.4 GB[\s\S]*?tv · 1 folder<\/span><span>102\.4 GB/)
    expect(html).to include('61 folders on this drive')
  end

  it 'shows how much of the NAS is not backed up, from the inventory' do
    manifest.assign_folder('movies/A', 'SN-backup-05-8tb', size_bytes: 10 * GB)
    manifest.replace_source_inventory([
      { folder_path: 'movies/A', size_bytes: 10 * GB, state: 'placed', detail: 'on backup-05-8tb' },
      { folder_path: 'movies/B', size_bytes: 30 * GB, state: 'unplaced', detail: 'no drive has room' },
      { folder_path: 'movies/C', size_bytes: 20 * GB, state: 'unplaced', detail: 'no drive has room' },
      { folder_path: 'Photos', size_bytes: 6 * TB, state: 'placed', detail: 'on backup-04-8tb' },
      { folder_path: 'synology', size_bytes: 2 * TB, state: 'unplaced', detail: 'no drive has room' }
    ])
    html = dashboard.render
    expect(html).to match(/<span class="share-name">synology<\/span>\s*<span class="share-meta">0 of 1 folders on the NAS backed up · 0 B of 2\.0 TB/)
    expect(html).to include('Nothing from this share fits on the mounted drives yet.')
    expect(html).to include('5 folders on the NAS, 2 backed up, 3 NOT backed up')
    expect(html).to match(%r{<strong>3 folders\s+\(2\.0 TB\) on the NAS are not backed up</strong>})
    expect(html).to include('1 of 3 folders on the NAS backed up · 10.0 GB of 60.0 GB')
    expect(html).to match(/<span class="share-name">Not backed up<\/span>[\s\S]*?movies\/B[\s\S]*?30\.0 GB[\s\S]*?no drive has room/)
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
