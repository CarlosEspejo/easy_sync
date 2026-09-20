# frozen_string_literal: true

RSpec.describe EasySync::Jbod::Runner do
  let(:mount_root) { File.join(temp_dir, 'Volumes') }
  let(:photos) { File.join(mount_root, 'photos') }   # whole share = one folder
  let(:tv) { File.join(mount_root, 'tv') }           # split: each show placed on its own
  let(:dashboard_path) { File.join(temp_dir, 'out', 'dashboard.html') }
  let(:settings) do
    EasySync::Config.defaults.merge(sources: [{ path: photos, split: false }, { path: tv, split: true }],
                                          mount_root: mount_root, dashboard_path: dashboard_path,
                                          exclude_folders: ['#recycle', '@eaDir'])
  end
  let(:clock) { double('clock', now: Time.utc(2026, 9, 13, 12, 0, 0)) }
  let(:manifest) { memory_manifest(clock: clock) }
  let(:drives) { register_fleet(manifest).to_h { |d| [d.friendly_name, d] } }
  let(:volume_info) { instance_double(EasySync::Jbod::VolumeInfo) }
  let(:mirror) { instance_double(EasySync::Jbod::Mirror) }
  let(:out) { StringIO.new }
  let(:sizes) { Hash.new(1_000) }
  let(:runner) { build_runner(settings) }

  def build_runner(settings, sizer: ->(path) { sizes[File.basename(path)] }, **opts)
    described_class.new(settings, manifest: manifest, volume_info: volume_info, mirror: mirror,
                                  shell: fake_shell, out: out, clock: clock, sizer: sizer, **opts)
  end

  def ok_result(total: 1_000, transferred: 10, extraneous: [])
    EasySync::Jbod::Mirror::Result.new(exit_status: 0, total_size_bytes: total, bytes_transferred: transferred,
                                       extraneous: extraneous, output: '')
  end

  def failed_result(status = 23)
    EasySync::Jbod::Mirror::Result.new(exit_status: status, total_size_bytes: nil, bytes_transferred: nil, output: '')
  end

  # A show folder on the NAS has episodes in it; a bare directory would be
  # (correctly) skipped as empty.
  def make_shows(*names)
    names.each { |n| write_file(File.join(tv, n, 'ep1.mkv')) }
  end

  def mount(name, free:, used: nil, at: "#{mount_root}/#{name}")
    mounted(drives[name], free: free, used: used, mount_point: at)
  end

  before do
    FileUtils.mkdir_p(mount_root)
    write_file(File.join(photos, '2024', 'IMG_0001.jpg'))
    drives
    # Best-effort lock detection: unstubbed tests treat every unmounted drive as
    # "can't tell" rather than expecting every test to know about it.
    allow(volume_info).to receive(:locked?).and_return(nil)
    allow(volume_info).to receive(:copy_state)
    allow(volume_info).to receive(:smart_health).and_return(
      EasySync::Jbod::Health.new(status: 'unknown', detail: 'not exposed', source: 'none')
    )
    allow(volume_info).to receive(:smartctl_model).and_return(nil)
  end

  describe '#sources' do
    it 'accepts hashes and plain path strings' do
      r = build_runner(settings.merge(sources: [photos, { path: tv, split: true }]))
      expect(r.sources.map(&:to_a)).to eq([[photos, false], [tv, true]])
      expect(r.sources.map(&:name)).to eq(%w[photos tv])
    end
  end

  describe '#source_folders' do
    it 'treats a whole share as one folder and each subfolder of a split share as its own' do
      make_shows('Show A', 'Show B', '#recycle', '@eaDir', '.hidden')
      folders, available = runner.source_folders
      expect(folders.map(&:key)).to eq(['photos', 'tv/Show A', 'tv/Show B'])
      expect(folders.map(&:path)).to eq([photos, "#{tv}/Show A", "#{tv}/Show B"])
      expect(available).to eq(%w[photos tv])
    end

    it 'warns loudly about loose files at the top of a split share, which are never backed up' do
      make_shows('Show A')
      write_file(File.join(tv, 'Stray Episode.mkv'))
      write_file(File.join(tv, '.DS_Store'))
      report = described_class::Report.new
      folders, = runner.source_folders(report)
      expect(folders.map(&:key)).to eq(['photos', 'tv/Show A'])
      expect(report.loose_files).to eq(['tv/Stray Episode.mkv'])
      expect(report.warnings).to include(a_string_matching(/1 loose file at the top level that will NOT be backed up.*Stray Episode\.mkv/))
    end

    it 'skips a share that is not mounted and reports it' do
      report = described_class::Report.new
      folders, available = runner.source_folders(report)
      expect(folders.map(&:key)).to eq(['photos'])
      expect(available).to eq(['photos'])
      expect(report.warnings).to include(a_string_matching(%r{source .*/tv is not mounted}))
    end

    it 'treats an empty mount point as not mounted, so --delete can never wipe a backup' do
      FileUtils.mkdir_p(tv)
      report = described_class::Report.new
      folders, = runner.source_folders(report)
      expect(folders.map(&:key)).to eq(['photos'])
      expect(report.warnings).to include(a_string_matching(%r{source .*/tv is not mounted}))
    end

    it 'refuses to run when no share is mounted' do
      FileUtils.rm_rf(photos)
      expect { runner.source_folders }.to raise_error(described_class::SourceUnavailable, /none of the configured sources/)
    end

    it 'refuses to run with no sources configured' do
      expect { build_runner(settings.merge(sources: [])).source_folders }
        .to raise_error(described_class::SourceUnavailable, /no sources configured/)
    end
  end

  describe '#run' do
    it 'places a new folder on the mounted drive with the most free space and syncs it' do
      sizes['photos'] = 5_000
      allow(volume_info).to receive(:mounted_drives).and_return([
        mount('backup-01-3tb', free: 1 * TB), mount('backup-05-8tb', free: 7 * TB), mount('backup-04-8tb', free: 6 * TB)
      ])
      expect(mirror).to receive(:sync).with(photos, "#{mount_root}/backup-05-8tb/photos").and_return(ok_result(total: 5_000))

      report = runner.run

      expect(report.placed).to eq([%w[photos backup-05-8tb]])
      expect(report.synced).to eq(['photos'])
      expect(manifest.folder('photos')).to have_attributes(drive_serial: 'SN-backup-05-8tb', size_bytes: 5_000,
                                                           last_sync_status: 'ok', last_synced_at: '2026-09-13T12:00:00Z')
      expect(manifest.history('photos').map(&:event)).to eq(['assigned'])
      expect(manifest.sync_runs.size).to eq(1)
    end

    it 'does not place a new folder where the manifest already promises more than df shows as used' do
      # backup-04-8tb (8 TB capacity) already has 7.5 TB of folders assigned
      # from an earlier, interrupted run that never got around to copying
      # them, so `df` still reports the drive as nearly empty (7.9 TB free).
      # A new 1 TB folder must not be placed there: 7.5 TB already promised
      # + 1 TB new leaves nothing for the drive to actually hold.
      manifest.assign_folder('tv/Old Show', 'SN-backup-04-8tb', size_bytes: (7.5 * TB).to_i)
      sizes['photos'] = 1 * TB
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 7.9 * TB)])

      report = runner.run

      expect(report.placed).to be_empty
      expect(report.unplaced).to eq(['photos'])
      expect(manifest.folder('photos')).to be_nil
    end

    it 'announces how many new folders it will measure and reports each as it goes' do
      make_shows('Show A')
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB)])
      allow(mirror).to receive(:sync).and_return(ok_result)
      runner.run
      expect(out.string).to include('2 new folders to measure and place', 'measuring photos (new folder 1)',
                                    'measuring tv/Show A (new folder 2)')
    end

    it 'mirrors a split-share subfolder under the share name on the drive' do
      make_shows('Show A')
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB)])
      expect(mirror).to receive(:sync).with(photos, "#{mount_root}/backup-04-8tb/photos").and_return(ok_result)
      expect(mirror).to receive(:sync).with("#{tv}/Show A", "#{mount_root}/backup-04-8tb/tv/Show A").and_return(ok_result)

      runner.run
      expect(manifest.folders.map(&:folder_path)).to eq(['photos', 'tv/Show A'])
    end

    it 'syncs an existing folder back to its assigned drive even when another drive has more room' do
      manifest.assign_folder('photos', 'SN-backup-01-3tb')
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-01-3tb', free: 10), mount('backup-07-8tb', free: 8 * TB)])
      expect(mirror).to receive(:sync).with(photos, "#{mount_root}/backup-01-3tb/photos").and_return(ok_result)

      report = runner.run
      expect(report.placed).to be_empty
      expect(manifest.folder('photos').drive_serial).to eq('SN-backup-01-3tb')
    end

    it 'follows the drive to a different mount point when the volume name moved' do
      manifest.assign_folder('photos', 'SN-backup-02-6tb')
      moved = "#{mount_root}/backup-02-6tb 1"
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-02-6tb', free: 1 * TB, at: moved)])
      expect(mirror).to receive(:sync).with(photos, "#{moved}/photos").and_return(ok_result)

      report = runner.run
      expect(report.warnings).to include(a_string_matching(/mounted at .*backup-02-6tb 1 \(matched by serial/))
    end

    it 'skips folders whose drive is not mounted and warns' do
      make_shows('Show A')
      manifest.assign_folder('photos', 'SN-backup-03-6tb')
      manifest.assign_folder('tv/Show A', 'SN-backup-04-8tb')
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB)])
      expect(mirror).to receive(:sync).once.with("#{tv}/Show A", "#{mount_root}/backup-04-8tb/tv/Show A").and_return(ok_result)

      report = runner.run
      expect(report.skipped).to eq(['photos'])
      expect(report.synced).to eq(['tv/Show A'])
      expect(manifest.folder('photos').last_sync_status).to eq('skipped_unmounted')
      expect(report.warnings).to include(a_string_matching(/photos: its drive backup-03-6tb is not mounted/))
      expect(report.warnings).to include(a_string_matching(/drive backup-01-3tb .* is not mounted/))
    end

    it 'names a detectably locked drive instead of a bare "not mounted"' do
      allow(volume_info).to receive(:mounted_drives).and_return([])
      allow(volume_info).to receive(:locked?).with('backup-01-3tb').and_return(true)

      report = runner.run
      expect(report.warnings).to include(a_string_matching(
        /backup-01-3tb .*: it's connected but still locked.*diskutil apfs unlockVolume backup-01-3tb/
      ))
      expect(report.warnings).to include(a_string_matching(/backup-02-6tb.*is not mounted$/))
    end

    it 'records SMART health for each mounted drive and warns about one starting to fail' do
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB), mount('backup-05-8tb', free: 1 * TB)])
      allow(volume_info).to receive(:smart_health).with("#{mount_root}/backup-04-8tb")
        .and_return(EasySync::Jbod::Health.new(status: 'ok', detail: 'PASSED · reallocated 0 · 34°C', source: 'smartctl',
                                               power_on_hours: 10_432))
      allow(volume_info).to receive(:smart_health).with("#{mount_root}/backup-05-8tb")
        .and_return(EasySync::Jbod::Health.new(status: 'warning', detail: 'PASSED · reallocated 12 · pending 3 · 41°C', source: 'smartctl',
                                               reallocated_sector_ct: 12, other_bad: true))
      allow(mirror).to receive(:sync).and_return(ok_result)

      report = runner.run
      expect(manifest.drive('SN-backup-04-8tb')).to have_attributes(smart_status: 'ok', smart_checked_at: '2026-09-13T12:00:00Z',
                                                                     power_on_hours: 10_432)
      expect(manifest.drive('SN-backup-05-8tb').smart_status).to eq('warning')
      expect(report.unhealthy).to eq([['backup-05-8tb', 'warning']])
      expect(report.warnings).to include(a_string_matching(/backup-05-8tb is starting to fail: SMART says PASSED · reallocated 12 · pending 3/))
      expect(report.warnings).not_to include(a_string_matching(/backup-04-8tb is/))
    end

    it 'downgrades a first-seen nonzero reallocated count to degraded_stable instead of alarming immediately' do
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB)])
      allow(volume_info).to receive(:smart_health).with("#{mount_root}/backup-04-8tb")
        .and_return(EasySync::Jbod::Health.new(status: 'warning', detail: 'PASSED · reallocated 24 · 34°C', source: 'smartctl',
                                               reallocated_sector_ct: 24, other_bad: false))
      allow(mirror).to receive(:sync).and_return(ok_result)

      report = runner.run
      expect(manifest.drive('SN-backup-04-8tb').smart_status).to eq('degraded_stable')
      expect(report.unhealthy).to eq([])
      expect(report.warnings).not_to include(a_string_matching(/backup-04-8tb/))
    end

    it 'alerts once the reallocated count grows past the first-seen baseline' do
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB)])
      allow(mirror).to receive(:sync).and_return(ok_result)
      manifest.record_smart_check('SN-backup-04-8tb', reallocated_sector_ct: 24)

      allow(volume_info).to receive(:smart_health).with("#{mount_root}/backup-04-8tb")
        .and_return(EasySync::Jbod::Health.new(status: 'warning', detail: 'PASSED · reallocated 26 · 34°C', source: 'smartctl',
                                               reallocated_sector_ct: 26, other_bad: false))

      report = runner.run
      expect(manifest.drive('SN-backup-04-8tb').smart_status).to eq('warning')
      expect(report.unhealthy).to eq([['backup-04-8tb', 'warning']])
    end

    it 'goes back to degraded_stable, not warning, once a full-surface scan verifies the count as stable' do
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB)])
      allow(mirror).to receive(:sync).and_return(ok_result)
      manifest.record_smart_check('SN-backup-04-8tb', reallocated_sector_ct: 24)
      manifest.verify_drive_stable('SN-backup-04-8tb', note: 'SpinRite: 0 new defects')

      allow(volume_info).to receive(:smart_health).with("#{mount_root}/backup-04-8tb")
        .and_return(EasySync::Jbod::Health.new(status: 'warning', detail: 'PASSED · reallocated 24 · 34°C', source: 'smartctl',
                                               reallocated_sector_ct: 24, other_bad: false))

      report = runner.run
      expect(manifest.drive('SN-backup-04-8tb').smart_status).to eq('degraded_stable')
      expect(report.unhealthy).to eq([])
    end

    it 'reports drive-full separately from a generic rsync failure and leaves the folder resumable' do
      manifest.assign_folder('photos', 'SN-backup-04-8tb')
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 500)])
      full_result = EasySync::Jbod::Mirror::Result.new(exit_status: 11, total_size_bytes: nil, bytes_transferred: nil,
                                                        extraneous: [], disk_full: true, output: 'No space left on device')
      allow(mirror).to receive(:sync).and_return(full_result)

      report = runner.run
      expect(report.drive_full).to eq(['photos'])
      expect(report.failed).to be_empty
      expect(manifest.folder('photos').last_sync_status).to eq('drive_full')
      expect(report.warnings).to include(a_string_matching(/photos did not fully sync: backup-04-8tb is full/))
      expect(File.read(dashboard_path)).to include('drive full')
    end

    it 'marks folders of an unmounted share as skipped rather than missing' do
      manifest.assign_folder('photos', 'SN-backup-04-8tb')
      manifest.assign_folder('tv/Show A', 'SN-backup-04-8tb')
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB)])
      expect(mirror).to receive(:sync).once.with(photos, anything).and_return(ok_result)

      report = runner.run
      expect(report.missing_on_source).to be_empty
      expect(report.skipped).to eq(['tv/Show A'])
      expect(manifest.folder('tv/Show A').last_sync_status).to eq('skipped_source_unmounted')
      expect(File.read(dashboard_path)).to include('share not mounted')
    end

    it 'never rebalances: a second run leaves placement untouched' do
      allow(volume_info).to receive(:mounted_drives).and_return(
        [mount('backup-01-3tb', free: 2 * TB), mount('backup-04-8tb', free: 1 * TB)],
        [mount('backup-01-3tb', free: 1), mount('backup-04-8tb', free: 8 * TB)]
      )
      allow(mirror).to receive(:sync).and_return(ok_result)

      runner.run
      build_runner(settings).run

      expect(mirror).to have_received(:sync).twice.with(anything, "#{mount_root}/backup-01-3tb/photos")
      expect(manifest.history('photos').size).to eq(1)
    end

    it 'accounts for folders placed earlier in the same run when choosing the next drive' do
      make_shows('A', 'B')
      sizes['photos'] = 0
      sizes['A'] = 600
      sizes['B'] = 100
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-01-3tb', free: 1_000), mount('backup-02-6tb', free: 900)])
      allow(mirror).to receive(:sync).and_return(ok_result)

      report = runner.run
      expect(report.placed).to eq([%w[photos backup-01-3tb], ['tv/A', 'backup-01-3tb'], ['tv/B', 'backup-02-6tb']])
    end

    it 'keeps the configured reserve free on a drive when placing' do
      sizes['photos'] = 950
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-01-3tb', free: 1_000)])
      expect(mirror).not_to receive(:sync)
      report = build_runner(settings.merge(reserve_bytes: 100)).run
      expect(report.unplaced).to eq(['photos'])
      expect(report.warnings).to include(a_string_matching(/does not fit on backup-01-3tb \(1000 B free, 100 B reserved\)/))
    end

    it 'does not place a folder that has no real files on the NAS' do
      make_dirs(tv, 'Empty Show', 'DS Only', 'Real Show')
      write_file(File.join(tv, 'DS Only', '.DS_Store'))
      write_file(File.join(tv, 'Real Show', 'Season 01', 'ep1.mkv'))
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB)])
      allow(mirror).to receive(:sync).and_return(ok_result)

      report = runner.run
      expect(report.empty).to eq(['tv/DS Only', 'tv/Empty Show'])
      expect(report.placed.map(&:first)).to eq(['photos', 'tv/Real Show'])
      expect(manifest.folder('tv/Empty Show')).to be_nil
      expect(report.warnings).to include(a_string_matching(%r{tv/DS Only has no files on the NAS}))
      expect(out.string).to include('empty 2')
    end

    it 'records an inventory of everything on the NAS: placed, unplaced and empty' do
      make_shows('Big Show', 'Small Show')
      make_dirs(tv, 'Empty Show')
      sizes['photos'] = 100
      sizes['Big Show'] = 5_000
      sizes['Small Show'] = 200
      manifest.assign_folder('photos', 'SN-backup-04-8tb', size_bytes: 100)
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1_000)])
      allow(mirror).to receive(:sync).and_return(ok_result)

      report = runner.run
      inv = manifest.source_inventory.to_h { |e| [e.folder_path, [e.state, e.size_bytes, e.detail]] }
      expect(inv).to eq('photos' => ['placed', 100, 'on backup-04-8tb'],
                        'tv/Big Show' => ['unplaced', 5_000, 'no drive has room'],
                        'tv/Empty Show' => ['empty', 0, 'no real files on the NAS'],
                        'tv/Small Show' => ['placed', 200, 'on backup-04-8tb'])
      expect(out.string).to include('Plan: 2 folders to sync (1 newly placed), 1 not backed up (4.9 KB: no room), 1 empty on the NAS')
      expect(report.unplaced).to eq(['tv/Big Show'])
    end

    it 'flags folders missing from the NAS before the copy phase begins' do
      make_shows('Show A')
      manifest.assign_folder('tv/Vanished', 'SN-backup-04-8tb')
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB)])
      allow(mirror).to receive(:sync).and_return(ok_result)
      runner.run
      expect(out.string.index('no longer on the NAS')).to be < out.string.index('------------------ ')
    end

    it 'decides every placement before the first copy, so an interrupted copy phase still leaves the full plan' do
      make_shows('A', 'B')
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB)])
      allow(mirror).to receive(:sync).and_return(ok_result)
      runner.run
      last_placement = out.string.rindex('Placing new folder')
      first_copy = out.string.index('------------------ ')
      expect(last_placement).to be < first_copy
      expect(out.string.index('Plan:')).to be < first_copy
    end

    it 'leaves a folder unplaced when it fits nowhere, without touching the manifest' do
      sizes['photos'] = 9 * TB
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-07-8tb', free: 8 * TB)])
      expect(mirror).not_to receive(:sync)

      report = runner.run
      expect(report.unplaced).to eq(['photos'])
      expect(manifest.folder('photos')).to be_nil
      expect(report.warnings).to include(a_string_matching(/cannot place photos: .*does not fit/))
    end

    it 'leaves new folders unplaced when no drive is mounted' do
      allow(volume_info).to receive(:mounted_drives).and_return([])
      expect(mirror).not_to receive(:sync)
      expect(runner.run.unplaced).to eq(['photos'])
    end

    it 'records a failed rsync and keeps going' do
      make_shows('B')
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB)])
      allow(mirror).to receive(:sync).and_return(failed_result(23), ok_result)

      report = runner.run
      expect(report.failed).to eq(['photos'])
      expect(report.synced).to eq(['tv/B'])
      expect(manifest.folder('photos')).to have_attributes(last_sync_status: 'failed', last_synced_at: nil)
      expect(manifest.sync_runs(folder_path: 'photos').first.exit_status).to eq(23)
    end

    it 'flags folders that vanished from a mounted share but keeps them in the manifest' do
      make_shows('Show A')
      manifest.assign_folder('photos', 'SN-backup-04-8tb')
      manifest.assign_folder('tv/Show A', 'SN-backup-04-8tb')
      manifest.assign_folder('tv/Cancelled Show', 'SN-backup-04-8tb')
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB)])
      allow(mirror).to receive(:sync).and_return(ok_result)

      report = runner.run
      expect(report.missing_on_source).to eq(['tv/Cancelled Show'])
      expect(manifest.folder('tv/Cancelled Show')).not_to be_nil
      expect(File.read(dashboard_path)).to include('missing on NAS')
    end

    it 'records live drive usage and writes the dashboard' do
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB, used: 7 * TB)])
      allow(mirror).to receive(:sync).and_return(ok_result)

      runner.run
      expect(manifest.drive('SN-backup-04-8tb')).to have_attributes(last_used_bytes: 7 * TB, last_free_bytes: 1 * TB,
                                                                     last_seen_at: '2026-09-13T12:00:00Z')
      html = File.read(dashboard_path)
      expect(html).to include('backup-04-8tb', 'photos', '88%')
      expect(manifest.drive('SN-backup-04-8tb')).to have_attributes(smart_status: 'unknown', smart_detail: 'not exposed')
      expect(out.string).to include("Dashboard written to #{dashboard_path}")
    end

    it 'backfills a drive model that smartctl can now provide but the manifest never recorded' do
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB, used: 7 * TB)])
      allow(volume_info).to receive(:smartctl_model).with("#{mount_root}/backup-04-8tb").and_return('WDC WD80EFZZ-68BTXN0')
      allow(mirror).to receive(:sync).and_return(ok_result)

      runner.run
      expect(manifest.drive('SN-backup-04-8tb').model).to eq('WDC WD80EFZZ-68BTXN0')
    end

    it 'stops asking smartctl for a model once the drive already has one' do
      manifest.update_drive_model('SN-backup-04-8tb', model: 'WDC WD80EFZZ-68BTXN0')
      fresh_drive = manifest.drive('SN-backup-04-8tb')   # drives[...] was cached before the update above
      allow(volume_info).to receive(:mounted_drives)
        .and_return([mounted(fresh_drive, free: 1 * TB, used: 7 * TB, mount_point: "#{mount_root}/backup-04-8tb")])
      allow(mirror).to receive(:sync).and_return(ok_result)

      runner.run
      expect(volume_info).not_to have_received(:smartctl_model)
    end

    it 'never backfills a model in dry-run' do
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB, used: 7 * TB)])
      allow(volume_info).to receive(:smartctl_model).and_return('WDC WD80EFZZ-68BTXN0')
      allow(mirror).to receive(:sync).and_return(ok_result)

      build_runner(settings, dry_run: true).run
      expect(manifest.drive('SN-backup-04-8tb').model).to be_nil
    end

    it 'lists loose files on the dashboard' do
      make_shows('Show A')
      write_file(File.join(tv, 'Stray Episode.mkv'))
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB)])
      allow(mirror).to receive(:sync).and_return(ok_result)
      runner.run
      expect(File.read(dashboard_path)).to include('1 loose file', 'tv/Stray Episode.mkv')
    end

    it 'copies the manifest and config to every mounted drive after the run, but not in dry-run' do
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB), mount('backup-05-8tb', free: 1 * TB)])
      allow(mirror).to receive(:sync).and_return(ok_result)
      build_runner(settings.merge(config_path: '/etc/easy.yml')).run
      expect(volume_info).to have_received(:copy_state).with("#{mount_root}/backup-04-8tb", manifest: manifest, config_path: '/etc/easy.yml').twice  # start and end
      expect(volume_info).to have_received(:copy_state).with("#{mount_root}/backup-05-8tb", manifest: manifest, config_path: '/etc/easy.yml').twice

      build_runner(settings, dry_run: true).run
      expect(volume_info).to have_received(:copy_state).exactly(4).times   # no new calls
    end

    it 'warns rather than fails when a drive refuses the state copy' do
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB)])
      allow(volume_info).to receive(:copy_state).and_raise(Errno::EROFS, 'read-only')
      allow(mirror).to receive(:sync).and_return(ok_result)
      report = runner.run
      expect(report.warnings).to include(a_string_matching(/could not copy the manifest to backup-04-8tb/))
      expect(File).to exist(dashboard_path)
    end

    it 'aborts before touching anything when no share is mounted' do
      FileUtils.rm_rf(photos)
      expect(mirror).not_to receive(:sync)
      expect { runner.run }.to raise_error(described_class::SourceUnavailable)
      expect(File).not_to exist(dashboard_path)
    end
  end

  describe 'grace-period deletions' do
    let(:drive_root) { "#{mount_root}/backup-04-8tb" }

    before do
      make_shows('Show A')
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB)])
    end

    it 'records what rsync would have deleted instead of deleting it' do
      allow(mirror).to receive(:sync).and_return(ok_result(extraneous: [['old.jpg', 'file']]), ok_result)
      report = runner.run
      expect(manifest.pending_deletions.map { |p| [p.folder_path, p.relative_path, p.missing_runs] }).to eq([['photos', 'old.jpg', 1]])
      expect(report.pending).to eq(1)
      expect(report.purged).to be_empty
      expect(out.string).to include('photos: 1 newly missing on NAS')
    end

    it 'warns and records nothing when the deletion probe failed' do
      manifest.assign_folder('photos', 'SN-backup-04-8tb')
      allow(mirror).to receive(:sync).and_return(ok_result(extraneous: nil), ok_result)
      report = runner.run
      expect(manifest.pending_deletions).to be_empty
      expect(report.warnings).to include(a_string_matching(/photos: the deletion probe failed/))
    end

    it 'purges a file once it has expired and the drive is mounted' do
      manifest.assign_folder('photos', 'SN-backup-04-8tb')
      manifest.reconcile_pending('photos', [['old.jpg', 'file']], at: '2026-09-01T00:00:00Z')
      write_file(File.join(drive_root, 'photos', 'old.jpg'))
      allow(mirror).to receive(:sync).and_return(ok_result(extraneous: [['old.jpg', 'file']]), ok_result)

      report = runner.run
      expect(report.purged).to eq([['photos', 'old.jpg', 'backup-04-8tb']])
      expect(File).not_to exist(File.join(drive_root, 'photos', 'old.jpg'))
      expect(manifest.deletions.size).to eq(1)
      expect(File.read(dashboard_path)).to include('Deleted from drives', 'photos/old.jpg')
    end

    it 'does not purge a file that reappeared on the NAS' do
      manifest.assign_folder('photos', 'SN-backup-04-8tb')
      manifest.reconcile_pending('photos', [['old.jpg', 'file']], at: '2026-09-01T00:00:00Z')
      write_file(File.join(drive_root, 'photos', 'old.jpg'))
      allow(mirror).to receive(:sync).and_return(ok_result(extraneous: []), ok_result)

      report = runner.run
      expect(report.purged).to be_empty
      expect(manifest.pending_deletions).to be_empty
      expect(File).to exist(File.join(drive_root, 'photos', 'old.jpg'))
    end

    it 'starts the clock on a whole folder that vanished from a mounted share, then removes it after the grace period' do
      manifest.assign_folder('tv/Cancelled', 'SN-backup-04-8tb')
      write_file(File.join(drive_root, 'tv', 'Cancelled', 'ep1.mkv'))
      allow(mirror).to receive(:sync).and_return(ok_result)

      runner.run
      expect(manifest.pending_deletions.map { |p| [p.folder_path, p.kind, p.missing_runs] }).to eq([['tv/Cancelled', 'folder', 1]])
      expect(Dir).to exist(File.join(drive_root, 'tv', 'Cancelled'))
      expect(File.read(dashboard_path)).to include('deleted from drive after 2026-09-20')

      manifest.db.execute("UPDATE pending_deletions SET first_missing_at = '2026-09-01T00:00:00Z'")
      report = build_runner(settings).run
      expect(report.purged).to eq([['tv/Cancelled', '', 'backup-04-8tb']])
      expect(Dir).not_to exist(File.join(drive_root, 'tv', 'Cancelled'))
      expect(manifest.folder('tv/Cancelled')).to be_nil
      expect(manifest.history('tv/Cancelled').map(&:event)).to eq(%w[removed assigned])
    end

    it 'does not start a clock for folders whose share is not mounted' do
      FileUtils.rm_rf(tv)
      manifest.assign_folder('tv/Show A', 'SN-backup-04-8tb')
      allow(mirror).to receive(:sync).and_return(ok_result)
      runner.run
      expect(manifest.pending_deletions).to be_empty
    end

    it 'honours --no-purge and purge: false' do
      manifest.assign_folder('photos', 'SN-backup-04-8tb')
      manifest.reconcile_pending('photos', [['old.jpg', 'file']], at: '2026-09-01T00:00:00Z')
      write_file(File.join(drive_root, 'photos', 'old.jpg'))
      allow(mirror).to receive(:sync).and_return(ok_result(extraneous: [['old.jpg', 'file']]))

      build_runner(settings, purge: false).run
      expect(File).to exist(File.join(drive_root, 'photos', 'old.jpg'))
      build_runner(settings.merge(purge: false)).run
      expect(File).to exist(File.join(drive_root, 'photos', 'old.jpg'))
      expect(manifest.pending_deletions.first.missing_runs).to eq(3)
    end

    it 'in dry-run mode writes nothing at all to the manifest and leaves the dashboard alone' do
      make_shows('Show A')
      manifest.assign_folder('photos', 'SN-backup-04-8tb')
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB, used: 7 * TB)])
      allow(mirror).to receive(:sync).and_return(ok_result(extraneous: [['gone.jpg', 'file']]))
      before = manifest.db.execute('SELECT * FROM folders').to_s + manifest.db.execute('SELECT * FROM drives').to_s

      report = build_runner(settings, dry_run: true).run

      expect(report.placed).to eq([['tv/Show A', 'backup-04-8tb']])           # decided, not recorded
      expect(manifest.folder('tv/Show A')).to be_nil
      expect(manifest.source_inventory).to be_empty
      expect(manifest.sync_runs).to be_empty
      expect(manifest.pending_deletions).to be_empty
      expect(manifest.history('tv/Show A')).to be_empty
      expect(manifest.folder('photos')).to have_attributes(last_sync_status: nil, last_synced_at: nil)
      expect(manifest.drive('SN-backup-04-8tb')).to have_attributes(last_used_bytes: nil, smart_status: nil)
      expect(manifest.db.execute('SELECT * FROM folders').to_s + manifest.db.execute('SELECT * FROM drives').to_s).to eq(before)
      expect(File).not_to exist(dashboard_path)
      expect(volume_info).not_to have_received(:copy_state)
      expect(out.string).to include('Would place new folder tv/Show A', 'DRY RUN: nothing was copied, recorded, or deleted')
    end

    it 'in dry-run mode touches neither the drives nor the pending table' do
      manifest.assign_folder('photos', 'SN-backup-04-8tb')
      manifest.reconcile_pending('photos', [['old.jpg', 'file']], at: '2026-09-01T00:00:00Z')
      manifest.reconcile_pending('photos', [['old.jpg', 'file']], at: '2026-09-05T00:00:00Z')
      write_file(File.join(drive_root, 'photos', 'old.jpg'))
      allow(mirror).to receive(:sync).and_return(ok_result(extraneous: [['old.jpg', 'file'], ['new.jpg', 'file']]))

      report = build_runner(settings, dry_run: true).run
      expect(report.would_purge).to eq([['photos', 'old.jpg', 'backup-04-8tb']])
      expect(File).to exist(File.join(drive_root, 'photos', 'old.jpg'))
      expect(manifest.pending_deletions.map { |p| [p.relative_path, p.missing_runs] }).to eq([['old.jpg', 2]])
    end
  end

  it 'hands the configured exclusions to the rsync it builds' do
    fake_shell.on('rsync', output: rsync_stats)
    fake_shell.on('du', output: "1\tx\n")
    allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB)])
    described_class.new(settings, manifest: manifest, volume_info: volume_info, shell: fake_shell, out: out, clock: clock).run
    copy, probe = fake_shell.calls_to('rsync')
    expect(copy).to include('--exclude=#recycle', '--exclude=@eaDir')
    expect(probe).to include('--delete-excluded', '--exclude=#recycle')
  end

  describe 'default sizer' do
    it 'uses du -sk and converts to bytes' do
      fake_shell.on('du', output: "2048\t#{photos}\n")
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB)])
      allow(mirror).to receive(:sync).and_return(ok_result(total: nil))
      described_class.new(settings, manifest: manifest, volume_info: volume_info, mirror: mirror,
                                    shell: fake_shell, out: out, clock: clock).run
      expect(manifest.folder('photos').size_bytes).to eq(2048 * 1024)
      expect(fake_shell.calls_to('du')).to eq([['du', '-sk', photos]])
    end
  end
end
