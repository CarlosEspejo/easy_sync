# frozen_string_literal: true

RSpec.describe EasySync::Jbod::Purger do
  let(:now) { Time.utc(2026, 9, 13, 12, 0, 0) }
  let(:clock) { double('clock', now: now) }
  let(:manifest) { memory_manifest(clock: clock) }
  let(:drives) { register_fleet(manifest).to_h { |d| [d.friendly_name, d] } }
  let(:mount_root) { File.join(temp_dir, 'Volumes') }
  let(:drive_root) { File.join(mount_root, 'backup-04-8tb') }
  let(:out) { StringIO.new }
  let(:purger) { described_class.new(manifest, grace_days: 7, grace_runs: 2, clock: clock, out: out) }
  let(:mounted_list) { [mounted(drives['backup-04-8tb'], free: 1 * TB, mount_point: drive_root)] }
  let(:long_ago) { '2026-09-01T00:00:00Z' }

  before do
    drives
    manifest.assign_folder('documents/Tax Returns', 'SN-backup-04-8tb')
    write_file(File.join(drive_root, 'documents', 'Tax Returns', 'scan.pdf'))
    write_file(File.join(drive_root, 'documents', 'Tax Returns', 'extras', 'appendix.pdf'))
    write_file(File.join(drive_root, 'documents', 'Tax Returns', 'old.txt'))
  end

  # Marks +paths+ as missing twice, the first time long enough ago to have expired.
  def expire(folder, paths)
    manifest.reconcile_pending(folder, paths, at: long_ago)
    manifest.reconcile_pending(folder, paths, at: now.iso8601)
  end

  it 'deletes expired files and empties directories deepest-first, recording each' do
    expire('documents/Tax Returns', [['old.txt', 'file'], ['extras', 'dir'], ['extras/appendix.pdf', 'file']])
    result = purger.run(mounted_list)

    expect(result.purged.map { |p, _| p.relative_path }).to contain_exactly('old.txt', 'extras/appendix.pdf', 'extras')
    expect(File).not_to exist(File.join(drive_root, 'documents', 'Tax Returns', 'old.txt'))
    expect(Dir).not_to exist(File.join(drive_root, 'documents', 'Tax Returns', 'extras'))
    expect(File).to exist(File.join(drive_root, 'documents', 'Tax Returns', 'scan.pdf'))
    expect(manifest.pending_deletions).to be_empty
    expect(manifest.deletions.map(&:relative_path)).to contain_exactly('old.txt', 'extras/appendix.pdf', 'extras')
  end

  it 'leaves candidates that have not expired alone' do
    manifest.reconcile_pending('documents/Tax Returns', [['old.txt', 'file']])
    result = purger.run(mounted_list)
    expect(result.purged).to be_empty
    expect(File).to exist(File.join(drive_root, 'documents', 'Tax Returns', 'old.txt'))
  end

  it 'removes a whole expired folder, its manifest row, and writes history' do
    expire('documents/Tax Returns', [['', 'folder']])
    result = purger.run(mounted_list)

    expect(result.purged.map { |p, _| p.kind }).to eq(['folder'])
    expect(Dir).not_to exist(File.join(drive_root, 'documents', 'Tax Returns'))
    expect(manifest.folder('documents/Tax Returns')).to be_nil
    expect(manifest.history('documents/Tax Returns').first).to have_attributes(event: 'removed')
    expect(manifest.history('documents/Tax Returns').first.note).to include('backup-04-8tb', 'missing on NAS since 2026-09-01')
    expect(manifest.deletions.first.kind).to eq('folder')
  end

  it 'does nothing in dry-run mode but says what it would do' do
    expire('documents/Tax Returns', [['old.txt', 'file']])
    result = purger.run(mounted_list, dry_run: true)
    expect(result.would_purge.map { |p, drive| [p.relative_path, drive] }).to eq([['old.txt', 'backup-04-8tb']])
    expect(result.purged).to be_empty
    expect(File).to exist(File.join(drive_root, 'documents', 'Tax Returns', 'old.txt'))
    expect(manifest.pending_deletions.size).to eq(1)
    expect(out.string).to include('would delete documents/Tax Returns/old.txt from backup-04-8tb')
  end

  it 'skips candidates whose drive is not mounted' do
    expire('documents/Tax Returns', [['old.txt', 'file']])
    result = purger.run([])
    expect(result.skipped.map { |p, why| [p.relative_path, why] }).to eq([['old.txt', 'drive not mounted']])
    expect(File).to exist(File.join(drive_root, 'documents', 'Tax Returns', 'old.txt'))
    expect(manifest.pending_deletions.size).to eq(1)
  end

  it 'refuses a path that escapes the folder' do
    expire('documents/Tax Returns', [['../../escape', 'file']])
    write_file(File.join(mount_root, 'escape'))
    result = purger.run(mounted_list)
    expect(result.skipped.map { |_, why| why }).to eq(['path escapes its folder'])
    expect(File).to exist(File.join(mount_root, 'escape'))
  end

  it 'leaves a directory that still has content and retries next time' do
    expire('documents/Tax Returns', [['extras', 'dir']])   # appendix.pdf inside is not a candidate
    result = purger.run(mounted_list)
    expect(result.purged).to be_empty
    expect(Dir).to exist(File.join(drive_root, 'documents', 'Tax Returns', 'extras'))
    expect(manifest.pending_deletions.size).to eq(1)
    expect(out.string).to include('not empty yet')
  end

  describe 'a whole-folder candidate that overlaps a live folder on the same drive' do
    let(:share) { File.join(drive_root, 'synology') }

    before do
      write_file(File.join(share, 'notes.txt'))
      write_file(File.join(share, 'Letters', 'a.pdf'))
    end

    it 'refuses to delete a folder that a live folder now sits inside (the old whole share after a split)' do
      manifest.assign_folder('synology', 'SN-backup-04-8tb')
      manifest.assign_folder('synology/Letters', 'SN-backup-04-8tb')
      expire('synology', [['', 'folder']])
      result = purger.run(mounted_list)

      expect(result.purged).to be_empty
      expect(result.skipped.map { |p, why| [p.folder_path, why] })
        .to eq([['synology', 'synology/Letters is a live folder that overlaps it on backup-04-8tb; not deleting (resolve by hand)']])
      expect(File).to exist(File.join(share, 'Letters', 'a.pdf'))
      expect(manifest.folder('synology')).not_to be_nil
      expect(manifest.pending_deletions.map(&:folder_path)).to eq(['synology'])
    end

    it 'refuses to delete a folder that is part of a live whole-share tree (split subfolders after a merge)' do
      manifest.assign_folder('synology/Letters', 'SN-backup-04-8tb')
      manifest.assign_folder('synology', 'SN-backup-04-8tb')
      expire('synology/Letters', [['', 'folder']])
      result = purger.run(mounted_list)

      expect(result.skipped.map { |_, why| why }.first).to start_with('synology is a live folder')
      expect(File).to exist(File.join(share, 'Letters', 'a.pdf'))
    end

    it 'still deletes a subfolder whose only overlap is its share\'s root-files unit' do
      manifest.assign_folder('synology', 'SN-backup-04-8tb', scope: 'root')
      manifest.assign_folder('synology/Letters', 'SN-backup-04-8tb')
      expire('synology/Letters', [['', 'folder']])
      result = purger.run(mounted_list)

      expect(result.purged.map { |p, _| p.folder_path }).to eq(['synology/Letters'])
      expect(Dir).not_to exist(File.join(share, 'Letters'))
      expect(File).to exist(File.join(share, 'notes.txt'))
    end

    it 'is not fooled by a name that merely starts with the same letters' do
      manifest.assign_folder('synology', 'SN-backup-04-8tb')
      manifest.assign_folder('synology-archive', 'SN-backup-04-8tb')
      expire('synology', [['', 'folder']])
      expect(purger.run(mounted_list).purged.map { |p, _| p.folder_path }).to eq(['synology'])
    end

    it 'ignores a live folder on a different drive' do
      manifest.assign_folder('synology', 'SN-backup-04-8tb')
      manifest.assign_folder('synology/Letters', 'SN-backup-05-8tb')
      expire('synology', [['', 'folder']])
      expect(purger.run(mounted_list).purged.map { |p, _| p.folder_path }).to eq(['synology'])
    end

    it 'leaves no empty share directory behind once the share\'s last folder is gone from the drive' do
      manifest.assign_folder('synology', 'SN-backup-04-8tb', scope: 'root')
      manifest.assign_folder('synology/Letters', 'SN-backup-04-8tb')
      expire('synology', [['', 'folder']])
      expire('synology/Letters', [['', 'folder']])
      purger.run(mounted_list)

      expect(Dir).not_to exist(share)
      expect(Dir).to exist(drive_root)
      expect(File).to exist(File.join(drive_root, 'documents', 'Tax Returns', 'scan.pdf'))
    end

    it 'removes only the top-level files of a root-files unit, never the subfolders below it' do
      manifest.assign_folder('synology', 'SN-backup-04-8tb', scope: 'root')
      manifest.assign_folder('synology/Letters', 'SN-backup-04-8tb')
      expire('synology', [['', 'folder']])
      result = purger.run(mounted_list)

      expect(result.purged.map { |p, _| p.folder_path }).to eq(['synology'])
      expect(File).not_to exist(File.join(share, 'notes.txt'))
      expect(File).to exist(File.join(share, 'Letters', 'a.pdf'))
      expect(manifest.folder('synology')).to be_nil
      expect(manifest.folder('synology/Letters')).not_to be_nil
    end
  end

  describe 'a folder reassigned off a drive' do
    let(:new_root) { File.join(mount_root, 'backup-05-8tb') }
    let(:both_mounted) { mounted_list + [mounted(drives['backup-05-8tb'], free: 1 * TB, mount_point: new_root)] }

    before do
      manifest.reassign_folder('documents/Tax Returns', 'SN-backup-05-8tb', at: long_ago)   # schedule_cleanup: true by default
    end

    it 'does not touch the old copy until the folder is verified synced to its new drive, even once grace_days has passed' do
      result = purger.run(both_mounted)
      expect(result.purged).to be_empty
      expect(result.skipped).to be_empty   # filtered out by readiness, never even attempted
      expect(File).to exist(File.join(drive_root, 'documents', 'Tax Returns', 'scan.pdf'))
      expect(manifest.folder('documents/Tax Returns').drive_serial).to eq('SN-backup-05-8tb')
    end

    it 'does not touch the old copy just because it synced ok, before grace_days has passed' do
      manifest.mark_folder_status('documents/Tax Returns', 'ok')
      purger = described_class.new(manifest, grace_days: 7, grace_runs: 2, clock: double('clock', now: Time.parse(long_ago) + 3600),
                                             out: out)
      result = purger.run(both_mounted)
      expect(result.purged).to be_empty
      expect(File).to exist(File.join(drive_root, 'documents', 'Tax Returns', 'scan.pdf'))
    end

    it 'deletes only the old drive copy once verified synced elsewhere and grace_days has passed, keeping the folder record' do
      manifest.mark_folder_status('documents/Tax Returns', 'ok')
      result = purger.run(both_mounted)

      expect(result.purged.map { |p, drive| [p.folder_path, drive] }).to eq([['documents/Tax Returns', 'backup-04-8tb']])
      expect(Dir).not_to exist(File.join(drive_root, 'documents', 'Tax Returns'))
      expect(manifest.folder('documents/Tax Returns')).to have_attributes(drive_serial: 'SN-backup-05-8tb', last_sync_status: 'ok')
      expect(manifest.pending_deletions).to be_empty
      expect(manifest.deletions.first).to have_attributes(folder_path: 'documents/Tax Returns', drive_serial: 'SN-backup-04-8tb')
    end

    it 'resolves the old drive from the pending candidate, not from the folder\'s current (new) assignment' do
      manifest.mark_folder_status('documents/Tax Returns', 'ok')
      result = purger.run(mounted_list)   # only the OLD drive is mounted; the new one is not

      expect(result.purged.map { |p, drive| [p.folder_path, drive] }).to eq([['documents/Tax Returns', 'backup-04-8tb']])
    end
  end
end
