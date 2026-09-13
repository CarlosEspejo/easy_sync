# frozen_string_literal: true

RSpec.describe EasySync::Jbod::Cleaner do
  let(:manifest) { memory_manifest }
  let(:drives) { register_fleet(manifest).to_h { |d| [d.friendly_name, d] } }
  let(:root) { File.join(temp_dir, 'Volumes', 'backup-04-8tb') }
  let(:out) { StringIO.new }
  let(:cleaner) { described_class.new(manifest, excludes: ['#recycle', '.DS_Store', '.smbdelete*'], out: out) }
  let(:mounted_list) { [mounted(drives['backup-04-8tb'], free: 1 * TB, mount_point: root)] }

  before do
    drives
    manifest.assign_folder('pro', 'SN-backup-04-8tb')
    write_file(File.join(root, 'pro', 'Course', 'lesson1.mp4'), 'x' * 100)
    write_file(File.join(root, 'pro', 'Course', '.DS_Store'), 'x' * 10)
    write_file(File.join(root, 'pro', '#recycle', 'old.mp4'), 'x' * 50)
    write_file(File.join(root, 'pro', '#recycle', 'deeper', '.DS_Store'), 'x' * 5)
    write_file(File.join(root, 'pro', '.smbdeleteAAA1'), 'x' * 3)
    write_file(File.join(root, '.easy_sync', 'drive.json'), '{}')
    write_file(File.join(root, 'unmanaged', '#recycle', 'keep.txt'))   # not a placed folder: never touched
    manifest.reconcile_pending('pro', [['#recycle', 'dir'], ['#recycle/old.mp4', 'file'], ['Course/.DS_Store', 'file'], ['real-missing.txt', 'file']])
  end

  it 'removes matching entries under placed folders only, counts bytes, and drops their pending rows' do
    result = cleaner.run(mounted_list)
    expect(result.removed).to eq([['pro', '#recycle'], ['pro', '.smbdeleteAAA1'], ['pro', 'Course/.DS_Store']])
    expect(result.bytes).to eq(50 + 5 + 3 + 10)
    expect(File).to exist(File.join(root, 'pro', 'Course', 'lesson1.mp4'))
    expect(File).not_to exist(File.join(root, 'pro', '#recycle'))
    expect(File).not_to exist(File.join(root, 'pro', 'Course', '.DS_Store'))
    expect(File).to exist(File.join(root, 'unmanaged', '#recycle', 'keep.txt'))
    expect(File).to exist(File.join(root, '.easy_sync', 'drive.json'))
    expect(manifest.pending_deletions.map(&:relative_path)).to eq(['real-missing.txt'])
    expect(out.string).to include('removed pro/#recycle (55 B) from backup-04-8tb')
  end

  it 'in dry-run mode lists but removes nothing' do
    result = cleaner.run(mounted_list, dry_run: true)
    expect(result.would_remove.size).to eq(3)
    expect(result.removed).to be_empty
    expect(File).to exist(File.join(root, 'pro', '#recycle', 'old.mp4'))
    expect(manifest.pending_deletions.size).to eq(4)
    expect(out.string).to include('would remove pro/#recycle')
  end

  it 'skips folders whose drive is not mounted' do
    expect(cleaner.run([]).removed).to be_empty
    expect(File).to exist(File.join(root, 'pro', '#recycle', 'old.mp4'))
  end
end
