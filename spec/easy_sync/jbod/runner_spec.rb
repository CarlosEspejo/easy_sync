# frozen_string_literal: true

RSpec.describe EasySync::Jbod::Runner do
  let(:mount_root) { File.join(temp_dir, 'Volumes') }
  let(:photos) { File.join(mount_root, 'photos') }   # whole share = one folder
  let(:tv) { File.join(mount_root, 'tv') }           # split: each show placed on its own
  let(:dashboard_path) { File.join(temp_dir, 'out', 'dashboard.html') }
  let(:settings) do
    EasySync::Config::JBOD_DEFAULTS.merge(sources: [{ path: photos, split: false }, { path: tv, split: true }],
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

  def build_runner(settings, sizer: ->(path) { sizes[File.basename(path)] })
    described_class.new(settings, manifest: manifest, volume_info: volume_info, mirror: mirror,
                                  shell: fake_shell, out: out, clock: clock, sizer: sizer)
  end

  def ok_result(total: 1_000, transferred: 10)
    EasySync::Jbod::Mirror::Result.new(exit_status: 0, total_size_bytes: total, bytes_transferred: transferred, output: '')
  end

  def failed_result(status = 23)
    EasySync::Jbod::Mirror::Result.new(exit_status: status, total_size_bytes: nil, bytes_transferred: nil, output: '')
  end

  def mount(name, free:, used: nil, at: "#{mount_root}/#{name}")
    mounted(drives[name], free: free, used: used, mount_point: at)
  end

  before do
    FileUtils.mkdir_p(mount_root)
    write_file(File.join(photos, '2024', 'IMG_0001.jpg'))
    drives
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
      make_dirs(tv, 'Show A', 'Show B', '#recycle', '@eaDir', '.hidden')
      write_file(File.join(tv, 'stray.txt'))
      folders, available = runner.source_folders
      expect(folders.map(&:key)).to eq(['photos', 'tv/Show A', 'tv/Show B'])
      expect(folders.map(&:path)).to eq([photos, "#{tv}/Show A", "#{tv}/Show B"])
      expect(available).to eq(%w[photos tv])
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

    it 'mirrors a split-share subfolder under the share name on the drive' do
      make_dirs(tv, 'Show A')
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
      make_dirs(tv, 'Show A')
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
      make_dirs(tv, 'A', 'B')
      sizes['photos'] = 0
      sizes['A'] = 600
      sizes['B'] = 100
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-01-3tb', free: 1_000), mount('backup-02-6tb', free: 900)])
      allow(mirror).to receive(:sync).and_return(ok_result)

      report = runner.run
      expect(report.placed).to eq([%w[photos backup-01-3tb], ['tv/A', 'backup-01-3tb'], ['tv/B', 'backup-02-6tb']])
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
      make_dirs(tv, 'B')
      allow(volume_info).to receive(:mounted_drives).and_return([mount('backup-04-8tb', free: 1 * TB)])
      allow(mirror).to receive(:sync).and_return(failed_result(23), ok_result)

      report = runner.run
      expect(report.failed).to eq(['photos'])
      expect(report.synced).to eq(['tv/B'])
      expect(manifest.folder('photos')).to have_attributes(last_sync_status: 'failed', last_synced_at: nil)
      expect(manifest.sync_runs(folder_path: 'photos').first.exit_status).to eq(23)
    end

    it 'flags folders that vanished from a mounted share but keeps them in the manifest' do
      make_dirs(tv, 'Show A')
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
      expect(html).to include('backup-04-8tb', 'photos', '88% full')
      expect(out.string).to include("Dashboard written to #{dashboard_path}")
    end

    it 'aborts before touching anything when no share is mounted' do
      FileUtils.rm_rf(photos)
      expect(mirror).not_to receive(:sync)
      expect { runner.run }.to raise_error(described_class::SourceUnavailable)
      expect(File).not_to exist(dashboard_path)
    end
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
