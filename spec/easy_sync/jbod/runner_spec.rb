# frozen_string_literal: true

RSpec.describe EasySync::Jbod::Runner do
  let(:source_root) { File.join(temp_dir, 'nas') }
  let(:mount_root) { File.join(temp_dir, 'Volumes') }
  let(:dashboard_path) { File.join(temp_dir, 'out', 'dashboard.html') }
  let(:settings) do
    EasySync::Config::JBOD_DEFAULTS.merge(source_root: source_root, mount_root: mount_root,
                                          dashboard_path: dashboard_path, exclude_folders: ['#recycle', '@eaDir'])
  end
  let(:clock) { double('clock', now: Time.utc(2026, 9, 13, 12, 0, 0)) }
  let(:manifest) { memory_manifest(clock: clock) }
  let(:drives) { register_fleet(manifest).to_h { |d| [d.friendly_name, d] } }
  let(:volume_info) { instance_double(EasySync::Jbod::VolumeInfo) }
  let(:mirror) { instance_double(EasySync::Jbod::Mirror) }
  let(:out) { StringIO.new }
  let(:sizes) { Hash.new(1_000) }
  let(:runner) do
    described_class.new(settings, manifest: manifest, volume_info: volume_info, mirror: mirror,
                                  shell: fake_shell, out: out, clock: clock,
                                  sizer: ->(path) { sizes[File.basename(path)] })
  end

  def ok_result(total: 1_000, transferred: 10)
    EasySync::Jbod::Mirror::Result.new(exit_status: 0, total_size_bytes: total, bytes_transferred: transferred, output: '')
  end

  def failed_result(status = 23)
    EasySync::Jbod::Mirror::Result.new(exit_status: status, total_size_bytes: nil, bytes_transferred: nil, output: '')
  end

  before do
    FileUtils.mkdir_p(source_root)
    FileUtils.mkdir_p(mount_root)
    drives
  end

  describe '#source_folders' do
    it 'lists top-level directories, skipping files, hidden and excluded names' do
      make_dirs(source_root, 'Photos', 'Music', '#recycle', '@eaDir', '.hidden')
      write_file(File.join(source_root, 'stray.txt'))
      expect(runner.source_folders).to eq(%w[Music Photos])
    end

    it 'refuses to run when the NAS is not mounted' do
      FileUtils.rm_rf(source_root)
      expect { runner.source_folders }.to raise_error(described_class::SourceUnavailable, /not mounted/)
    end

    it 'refuses to run against an empty source, so --delete can never wipe the backups' do
      expect { runner.source_folders }.to raise_error(described_class::SourceUnavailable, /no folders/)
    end
  end

  describe '#run' do
    it 'places a new folder on the mounted drive with the most free space and syncs it' do
      make_dirs(source_root, 'Photos')
      sizes['Photos'] = 5_000
      allow(volume_info).to receive(:mounted_drives).and_return([
        mounted(drives['backup-01-3tb'], free: 1 * TB, mount_point: "#{mount_root}/backup-01-3tb"),
        mounted(drives['backup-05-8tb'], free: 7 * TB, mount_point: "#{mount_root}/backup-05-8tb"),
        mounted(drives['backup-04-8tb'], free: 6 * TB, mount_point: "#{mount_root}/backup-04-8tb")
      ])
      expect(mirror).to receive(:sync).with("#{source_root}/Photos", "#{mount_root}/backup-05-8tb/Photos")
                                      .and_return(ok_result(total: 5_000))

      report = runner.run

      expect(report.placed).to eq([%w[Photos backup-05-8tb]])
      expect(report.synced).to eq(['Photos'])
      folder = manifest.folder('Photos')
      expect(folder).to have_attributes(drive_serial: 'SN-backup-05-8tb', size_bytes: 5_000,
                                        last_sync_status: 'ok', last_synced_at: '2026-09-13T12:00:00Z')
      expect(manifest.history('Photos').map(&:event)).to eq(['assigned'])
      expect(manifest.sync_runs.size).to eq(1)
    end

    it 'syncs an existing folder back to its assigned drive even when another drive has more room' do
      make_dirs(source_root, 'Photos')
      manifest.assign_folder('Photos', 'SN-backup-01-3tb')
      allow(volume_info).to receive(:mounted_drives).and_return([
        mounted(drives['backup-01-3tb'], free: 10, mount_point: "#{mount_root}/backup-01-3tb"),
        mounted(drives['backup-07-8tb'], free: 8 * TB, mount_point: "#{mount_root}/backup-07-8tb")
      ])
      expect(mirror).to receive(:sync).with("#{source_root}/Photos", "#{mount_root}/backup-01-3tb/Photos")
                                      .and_return(ok_result)

      report = runner.run
      expect(report.placed).to be_empty
      expect(manifest.folder('Photos').drive_serial).to eq('SN-backup-01-3tb')
    end

    it 'follows the drive to a different mount point when the volume name moved' do
      make_dirs(source_root, 'Photos')
      manifest.assign_folder('Photos', 'SN-backup-02-6tb')
      moved = "#{mount_root}/backup-02-6tb 1"
      allow(volume_info).to receive(:mounted_drives).and_return([mounted(drives['backup-02-6tb'], free: 1 * TB, mount_point: moved)])
      expect(mirror).to receive(:sync).with("#{source_root}/Photos", "#{moved}/Photos").and_return(ok_result)

      report = runner.run
      expect(report.warnings).to include(a_string_matching(/mounted at .*backup-02-6tb 1 \(matched by serial/))
    end

    it 'skips folders whose drive is not mounted and warns' do
      make_dirs(source_root, 'Photos', 'Music')
      manifest.assign_folder('Photos', 'SN-backup-03-6tb')
      manifest.assign_folder('Music', 'SN-backup-04-8tb')
      allow(volume_info).to receive(:mounted_drives).and_return([mounted(drives['backup-04-8tb'], free: 1 * TB, mount_point: "#{mount_root}/backup-04-8tb")])
      expect(mirror).to receive(:sync).once.with("#{source_root}/Music", anything).and_return(ok_result)

      report = runner.run
      expect(report.skipped).to eq(['Photos'])
      expect(report.synced).to eq(['Music'])
      expect(manifest.folder('Photos').last_sync_status).to eq('skipped_unmounted')
      expect(report.warnings).to include(a_string_matching(/Photos: its drive backup-03-6tb is not mounted/))
      expect(report.warnings).to include(a_string_matching(/drive backup-01-3tb .* is not mounted/))
    end

    it 'never rebalances: a second run leaves placement untouched' do
      make_dirs(source_root, 'Photos')
      allow(volume_info).to receive(:mounted_drives).and_return(
        [mounted(drives['backup-01-3tb'], free: 2 * TB, mount_point: "#{mount_root}/backup-01-3tb"),
         mounted(drives['backup-04-8tb'], free: 1 * TB, mount_point: "#{mount_root}/backup-04-8tb")],
        [mounted(drives['backup-01-3tb'], free: 1, mount_point: "#{mount_root}/backup-01-3tb"),
         mounted(drives['backup-04-8tb'], free: 8 * TB, mount_point: "#{mount_root}/backup-04-8tb")]
      )
      allow(mirror).to receive(:sync).and_return(ok_result)

      runner.run
      described_class.new(settings, manifest: manifest, volume_info: volume_info, mirror: mirror,
                                    shell: fake_shell, out: out, clock: clock, sizer: ->(_) { 1 }).run

      expect(mirror).to have_received(:sync).twice.with(anything, "#{mount_root}/backup-01-3tb/Photos")
      expect(manifest.history('Photos').size).to eq(1)
    end

    it 'accounts for folders placed earlier in the same run when choosing the next drive' do
      make_dirs(source_root, 'A', 'B')
      sizes['A'] = 600
      sizes['B'] = 100
      allow(volume_info).to receive(:mounted_drives).and_return([
        mounted(drives['backup-01-3tb'], free: 1_000, mount_point: "#{mount_root}/backup-01-3tb"),
        mounted(drives['backup-02-6tb'], free: 900, mount_point: "#{mount_root}/backup-02-6tb")
      ])
      allow(mirror).to receive(:sync).and_return(ok_result)

      report = runner.run
      expect(report.placed).to eq([%w[A backup-01-3tb], %w[B backup-02-6tb]])
    end

    it 'leaves a folder unplaced when it fits nowhere, without touching the manifest' do
      make_dirs(source_root, 'Huge')
      sizes['Huge'] = 9 * TB
      allow(volume_info).to receive(:mounted_drives).and_return([mounted(drives['backup-07-8tb'], free: 8 * TB, mount_point: "#{mount_root}/backup-07-8tb")])
      expect(mirror).not_to receive(:sync)

      report = runner.run
      expect(report.unplaced).to eq(['Huge'])
      expect(manifest.folder('Huge')).to be_nil
      expect(report.warnings).to include(a_string_matching(/cannot place Huge: .*does not fit/))
    end

    it 'leaves new folders unplaced when no drive is mounted' do
      make_dirs(source_root, 'Photos')
      allow(volume_info).to receive(:mounted_drives).and_return([])
      expect(mirror).not_to receive(:sync)
      report = runner.run
      expect(report.unplaced).to eq(['Photos'])
    end

    it 'records a failed rsync and keeps going' do
      make_dirs(source_root, 'A', 'B')
      allow(volume_info).to receive(:mounted_drives).and_return([mounted(drives['backup-04-8tb'], free: 1 * TB, mount_point: "#{mount_root}/backup-04-8tb")])
      allow(mirror).to receive(:sync).and_return(failed_result(23), ok_result)

      report = runner.run
      expect(report.failed).to eq(['A'])
      expect(report.synced).to eq(['B'])
      expect(manifest.folder('A')).to have_attributes(last_sync_status: 'failed', last_synced_at: nil)
      expect(manifest.sync_runs(folder_path: 'A').first.exit_status).to eq(23)
    end

    it 'flags folders that vanished from the NAS but stays on the manifest' do
      make_dirs(source_root, 'Photos')
      manifest.assign_folder('Photos', 'SN-backup-04-8tb')
      manifest.assign_folder('OldStuff', 'SN-backup-04-8tb')
      allow(volume_info).to receive(:mounted_drives).and_return([mounted(drives['backup-04-8tb'], free: 1 * TB, mount_point: "#{mount_root}/backup-04-8tb")])
      allow(mirror).to receive(:sync).and_return(ok_result)

      report = runner.run
      expect(report.missing_on_source).to eq(['OldStuff'])
      expect(manifest.folder('OldStuff')).not_to be_nil
      expect(File.read(dashboard_path)).to include('missing on NAS')
    end

    it 'records live drive usage and writes the dashboard' do
      make_dirs(source_root, 'Photos')
      allow(volume_info).to receive(:mounted_drives).and_return([mounted(drives['backup-04-8tb'], free: 1 * TB, used: 7 * TB, mount_point: "#{mount_root}/backup-04-8tb")])
      allow(mirror).to receive(:sync).and_return(ok_result)

      runner.run
      expect(manifest.drive('SN-backup-04-8tb')).to have_attributes(last_used_bytes: 7 * TB, last_free_bytes: 1 * TB,
                                                                     last_seen_at: '2026-09-13T12:00:00Z')
      html = File.read(dashboard_path)
      expect(html).to include('backup-04-8tb', 'Photos', '88% full')
      expect(out.string).to include("Dashboard written to #{dashboard_path}")
    end

    it 'aborts before touching anything when the NAS is missing' do
      FileUtils.rm_rf(source_root)
      expect(mirror).not_to receive(:sync)
      expect { runner.run }.to raise_error(described_class::SourceUnavailable)
      expect(File).not_to exist(dashboard_path)
    end
  end

  describe 'default sizer' do
    it 'uses du -sk and converts to bytes' do
      make_dirs(source_root, 'Photos')
      fake_shell.on('du', output: "2048\t#{source_root}/Photos\n")
      allow(volume_info).to receive(:mounted_drives).and_return([mounted(drives['backup-04-8tb'], free: 1 * TB, mount_point: "#{mount_root}/backup-04-8tb")])
      allow(mirror).to receive(:sync).and_return(ok_result(total: nil))
      described_class.new(settings, manifest: manifest, volume_info: volume_info, mirror: mirror,
                                    shell: fake_shell, out: out, clock: clock).run
      expect(manifest.folder('Photos').size_bytes).to eq(2048 * 1024)
      expect(fake_shell.calls_to('du')).to eq([['du', '-sk', "#{source_root}/Photos"]])
    end
  end
end
