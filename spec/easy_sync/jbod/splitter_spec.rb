# frozen_string_literal: true

RSpec.describe EasySync::Jbod::Splitter do
  let(:now) { Time.utc(2026, 9, 23, 12, 0, 0) }
  let(:clock) { double('clock', now: now) }
  let(:manifest) { memory_manifest(clock: clock) }
  let(:drives) { register_fleet(manifest).to_h { |d| [d.friendly_name, d] } }
  let(:serial) { 'SN-backup-04-8tb' }
  let(:nas) { File.join(temp_dir, 'nas', 'synology') }
  let(:drive_root) { File.join(temp_dir, 'Volumes', 'backup-04-8tb') }
  let(:on_drive) { File.join(drive_root, 'synology') }
  let(:settings) { { sources: [{ path: nas }], exclude_folders: ['#recycle', '.DS_Store'] } }
  let(:volume_info) { instance_double(EasySync::Jbod::VolumeInfo) }
  let(:out) { StringIO.new }
  let(:sizes) { { 'Movies' => 5_000, 'TV' => 3_000, 'OldShow' => 700 } }
  let(:splitter) do
    described_class.new(settings, manifest: manifest, volume_info: volume_info, shell: fake_shell, out: out,
                                  sizer: ->(path) { sizes.fetch(File.basename(path)) })
  end

  before do
    drives
    manifest.assign_folder('synology', serial, size_bytes: 8_710)
    write_file(File.join(nas, 'Movies', 'a.mkv'))
    write_file(File.join(nas, 'TV', 't.mkv'))
    write_file(File.join(nas, 'notes.txt'), 'x' * 10)
    write_file(File.join(nas, '#recycle', 'junk'))
    write_file(File.join(on_drive, 'Movies', 'a.mkv'))
    write_file(File.join(on_drive, 'TV', 't.mkv'))
    write_file(File.join(on_drive, 'OldShow', 'x.mkv'))   # deleted from the NAS since the last sync
    write_file(File.join(on_drive, 'notes.txt'), 'x' * 10)
    allow(volume_info).to receive(:mounted_drives).and_return([mounted(drives['backup-04-8tb'], free: 1 * TB, mount_point: drive_root)])
  end

  def dump
    %w[folders pending_deletions file_checksums placement_history].to_h { |t| [t, manifest.db.execute("SELECT * FROM #{t}")] }
  end

  it 'turns a share placed whole into one folder per subfolder plus a root unit, all on the same drive, copying nothing' do
    splitter.run('synology')

    expect(manifest.folders.map { |f| [f.folder_path, f.drive_serial, f.scope, f.size_bytes] }).to eq([
      ['synology', serial, 'root', 10],
      ['synology/Movies', serial, 'tree', 5_000],
      ['synology/OldShow', serial, 'tree', 700],
      ['synology/TV', serial, 'tree', 3_000]
    ])
    expect(fake_shell.calls).to be_empty   # no rsync, no du (sizer stubbed): nothing is copied
    expect(manifest.pending_deletions).to be_empty
    expect(manifest.history('synology').first).to have_attributes(event: 'split')
    expect(manifest.history('synology/Movies').first.note).to include('no data moved')
    expect(out.string).to include('Splitting synology on backup-04-8tb into 3 folders', 'synology/OldShow',
                                  'only on the drive', 'The next sync checks them in place')
  end

  it 'never leaves a whole-folder deletion behind for the old share, so Purger cannot remove the new folders' do
    splitter.run('synology')
    runner_view = manifest.folders.map(&:folder_path)
    expect(runner_view).to include('synology')   # still a folder (the root unit): never reported missing
    expect(manifest.pending_deletions.select { |p| p.folder_path == 'synology' && p.whole_folder? }).to be_empty
  end

  it 'moves pending deletions onto the new folders, keeping their grace clocks' do
    manifest.reconcile_pending('synology', [['Movies/old.mkv', 'file'], ['OldShow', 'dir'], ['OldShow/x.mkv', 'file'],
                                            ['Gone', 'dir'], ['Gone/y.mkv', 'file'], ['stale.txt', 'file']],
                               at: '2026-09-01T00:00:00Z')
    splitter.run('synology')

    expect(manifest.pending_deletions.map { |p| [p.folder_path, p.relative_path, p.kind, p.first_missing_at] }).to contain_exactly(
      ['synology', 'stale.txt', 'file', '2026-09-01T00:00:00Z'],
      ['synology/Movies', 'old.mkv', 'file', '2026-09-01T00:00:00Z'],
      ['synology/OldShow', '', 'folder', '2026-09-01T00:00:00Z'],
      ['synology/OldShow', 'x.mkv', 'file', '2026-09-01T00:00:00Z']
    )   # Gone/ is on neither the NAS nor the drive: nothing left to delete, so its rows are dropped
  end

  it 'keeps scrub baselines, re-keyed to the new folders, instead of forcing a full re-hash' do
    manifest.reconcile_checksums(serial, 'synology', { 'Movies/a.mkv' => [1, 1], 'notes.txt' => [10, 1] })
    manifest.checksum_hashed(serial, 'synology', 'Movies/a.mkv', outcome: :baseline, digest: 'aaa')
    manifest.checksum_hashed(serial, 'synology', 'notes.txt', outcome: :baseline, digest: 'nnn')
    splitter.run('synology')

    expect(manifest.checksum_rows(serial, 'synology/Movies').map { |r| [r.relative_path, r.digest, r.status] })
      .to eq([['a.mkv', 'aaa', 'ok']])
    expect(manifest.checksum_rows(serial, 'synology').map { |r| [r.relative_path, r.digest] }).to eq([['notes.txt', 'nnn']])
  end

  it 'writes nothing in dry-run, but says what it would do' do
    before = dump
    splitter.run('synology', dry_run: true)
    expect(dump).to eq(before)
    expect(out.string).to include('Would split synology on backup-04-8tb into 3 folders')
  end

  it 'does nothing for a share that is already placed folder by folder' do
    splitter.run('synology')
    out.truncate(0); out.rewind
    before = dump
    expect(splitter.run('synology')).to be_nil
    expect(dump).to eq(before)
    expect(out.string).to include('not placed whole', 'Nothing to do')
  end

  describe 'refuses, changing nothing' do
    it 'when the share is not a configured source' do
      manifest.assign_folder('photos', serial)
      expect { splitter.run('photos') }.to raise_error(EasySync::Error, /photos is not a configured source/)
    end

    it 'when the NAS share is not mounted' do
      FileUtils.rm_rf(nas)
      expect { splitter.run('synology') }.to raise_error(EasySync::Error, /not mounted .* reads the share's folders from the NAS/)
      expect(manifest.folder('synology').scope).to eq('tree')
    end

    it 'when the drive holding it is not mounted' do
      allow(volume_info).to receive(:mounted_drives).and_return([])
      expect { splitter.run('synology') }.to raise_error(EasySync::Error, /connect backup-04-8tb first/)
    end

    it 'while an older copy from a reassign is still waiting to be deleted' do
      manifest.reassign_folder('synology', 'SN-backup-05-8tb')
      expect { splitter.run('synology') }.to raise_error(EasySync::Error, /older copy of synology on backup-04-8tb is still waiting/)
      expect(manifest.folders.map(&:folder_path)).to eq(['synology'])
    end

    it 'if any new folder already has a row, rolling back the whole split' do
      manifest.assign_folder('synology/TV', 'SN-backup-05-8tb')
      expect { splitter.run('synology') }.to raise_error(EasySync::Jbod::Manifest::DuplicateFolder)
      expect(manifest.folders.map(&:folder_path)).to eq(['synology', 'synology/TV'])
      expect(manifest.folder('synology').scope).to eq('tree')
    end
  end
end
