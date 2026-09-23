# frozen_string_literal: true

RSpec.describe EasySync::Jbod::Restorer do
  let(:manifest) { memory_manifest }
  let(:drives) { register_fleet(manifest).to_h { |d| [d.friendly_name, d] } }
  let(:nas) { File.join(temp_dir, 'Volumes') }
  let(:drive_root) { File.join(temp_dir, 'Volumes', 'backup-04-8tb') }
  let(:out) { StringIO.new }
  let(:settings) do
    { exclude_folders: ['#recycle', '.DS_Store'],
      sources: [{ path: File.join(nas, 'tv') }, { path: File.join(nas, 'pro') }] }
  end
  let(:restorer) { described_class.new(settings, manifest: manifest, shell: fake_shell, out: out) }
  let(:mounted_list) { [mounted(drives['backup-04-8tb'], free: 1 * TB, mount_point: drive_root)] }

  before do
    drives
    manifest.assign_folder('tv/Breaking Bad', 'SN-backup-04-8tb')
    manifest.assign_folder('pro', 'SN-backup-04-8tb')
    write_file(File.join(drive_root, 'tv', 'Breaking Bad', 'S01E01.mp4'), 'x' * 100)
    write_file(File.join(drive_root, 'pro', 'Course', 'lesson1.mp4'), 'x' * 100)
    FileUtils.mkdir_p(File.join(nas, 'tv'))
    FileUtils.mkdir_p(File.join(nas, 'pro'))
  end

  describe '#resolve' do
    it 'matches an exact folder_path' do
      expect(restorer.resolve(['pro']).map(&:folder_path)).to eq(['pro'])
    end

    it 'expands a share name to every folder placed under it' do
      expect(restorer.resolve(['tv']).map(&:folder_path)).to eq(['tv/Breaking Bad'])
    end

    it 'de-duplicates when a target and its share both match' do
      expect(restorer.resolve(['tv', 'tv/Breaking Bad']).map(&:folder_path)).to eq(['tv/Breaking Bad'])
    end

    it 'expands a share name to its root-files unit plus every folder under it' do
      manifest.assign_folder('tv', 'SN-backup-04-8tb', scope: 'root')
      expect(restorer.resolve(['tv']).map(&:folder_path)).to eq(['tv', 'tv/Breaking Bad'])
    end

    it 'raises for a name matching nothing placed' do
      expect { restorer.resolve(['movies']) }.to raise_error(EasySync::Jbod::Restorer::UnknownTarget, /movies/)
    end
  end

  describe '#run' do
    it 'rsyncs each folder from its drive back onto the configured NAS share, with --partial and no --delete' do
      fake_shell.on('rsync', output: rsync_stats)
      result = restorer.run(manifest.folders, mounted_list)
      expect(result.restored).to contain_exactly('tv/Breaking Bad', 'pro')
      expect(result.skipped).to be_empty
      expect(result.failed).to be_empty

      calls = fake_shell.calls_to('rsync')
      expect(calls.size).to eq(2)
      calls.each do |argv|
        expect(argv).to include('-a', '--partial')
        expect(argv).not_to include('--delete')
      end
      tv_call = calls.find { |a| a.last(2).first.include?('Breaking Bad') }
      expect(tv_call.last(2)).to eq(["#{File.join(drive_root, 'tv/Breaking Bad')}/", "#{File.join(nas, 'tv/Breaking Bad')}/"])
    end

    it 'restores only the top-level files of a root-files unit' do
      manifest.assign_folder('tv', 'SN-backup-04-8tb', scope: 'root')
      write_file(File.join(drive_root, 'tv', 'notes.txt'))
      fake_shell.on('rsync', output: rsync_stats)
      restorer.run([manifest.folder('tv')], mounted_list)
      call = fake_shell.calls_to('rsync').last
      expect(call).to include('--exclude=/*/')
      expect(call.last(2)).to eq(["#{drive_root}/tv/", "#{nas}/tv/"])
    end

    it 'skips a folder whose drive is not mounted' do
      result = restorer.run(manifest.folders, [])
      expect(result.skipped).to contain_exactly('tv/Breaking Bad', 'pro')
      expect(out.string).to include('its drive backup-04-8tb is not mounted')
    end

    it 'skips a folder whose share is no longer configured' do
      manifest.assign_folder('synology', 'SN-backup-04-8tb')
      write_file(File.join(drive_root, 'synology', 'file.txt'))
      result = restorer.run([manifest.folder('synology')], mounted_list)
      expect(result.skipped).to eq(['synology'])
      expect(out.string).to include('synology is not a configured source')
    end

    it 'skips a folder whose NAS share is not mounted' do
      FileUtils.rm_rf(File.join(nas, 'pro'))
      result = restorer.run([manifest.folder('pro')], mounted_list)
      expect(result.skipped).to eq(['pro'])
      expect(out.string).to include('the NAS share is not mounted')
    end

    it 'skips a folder with nothing at its drive path' do
      FileUtils.rm_rf(File.join(drive_root, 'pro'))
      result = restorer.run([manifest.folder('pro')], mounted_list)
      expect(result.skipped).to eq(['pro'])
      expect(out.string).to include('nothing at')
    end

    it 'records a failed rsync without raising' do
      fake_shell.on('rsync', output: 'boom', status: 23)
      result = restorer.run([manifest.folder('pro')], mounted_list)
      expect(result.failed).to eq(['pro'])
      expect(out.string).to include('rsync for pro exited with status 23')
    end

    it 'in dry-run mode passes --dry-run to rsync' do
      fake_shell.on('rsync', output: rsync_stats)
      restorer.run([manifest.folder('pro')], mounted_list, dry_run: true)
      expect(fake_shell.calls_to('rsync').first).to include('--dry-run')
    end

    it 'warns and names every scrub-flagged file before restoring a folder that has one, but still restores it' do
      manifest.reconcile_checksums('SN-backup-04-8tb', 'pro', { 'Course/lesson1.mp4' => [400, 400] })
      manifest.checksum_hashed('SN-backup-04-8tb', 'pro', 'Course/lesson1.mp4', outcome: :corrupt, at: '2026-09-01T00:00:00Z')
      fake_shell.on('rsync', output: rsync_stats)

      result = restorer.run([manifest.folder('pro')], mounted_list)
      expect(result.restored).to eq(['pro'])
      expect(out.string).to include('WARNING: pro: 1 file on backup-04-8tb is flagged by scrub ' \
                                    '(Course/lesson1.mp4: corrupt); restoring may copy a rotted file onto the NAS.')
    end

    it 'says nothing about scrub when nothing is flagged' do
      fake_shell.on('rsync', output: rsync_stats)
      restorer.run([manifest.folder('pro')], mounted_list)
      expect(out.string).not_to include('flagged by scrub')
    end
  end
end
