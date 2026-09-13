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
    manifest.assign_folder('movies/Heat (1995)', 'SN-backup-04-8tb')
    write_file(File.join(drive_root, 'movies', 'Heat (1995)', 'movie.mkv'))
    write_file(File.join(drive_root, 'movies', 'Heat (1995)', 'extras', 'trailer.mkv'))
    write_file(File.join(drive_root, 'movies', 'Heat (1995)', 'old.srt'))
  end

  # Marks +paths+ as missing twice, the first time long enough ago to have expired.
  def expire(folder, paths)
    manifest.reconcile_pending(folder, paths, at: long_ago)
    manifest.reconcile_pending(folder, paths, at: now.iso8601)
  end

  it 'deletes expired files and empties directories deepest-first, recording each' do
    expire('movies/Heat (1995)', [['old.srt', 'file'], ['extras', 'dir'], ['extras/trailer.mkv', 'file']])
    result = purger.run(mounted_list)

    expect(result.purged.map { |p, _| p.relative_path }).to contain_exactly('old.srt', 'extras/trailer.mkv', 'extras')
    expect(File).not_to exist(File.join(drive_root, 'movies', 'Heat (1995)', 'old.srt'))
    expect(Dir).not_to exist(File.join(drive_root, 'movies', 'Heat (1995)', 'extras'))
    expect(File).to exist(File.join(drive_root, 'movies', 'Heat (1995)', 'movie.mkv'))
    expect(manifest.pending_deletions).to be_empty
    expect(manifest.deletions.map(&:relative_path)).to contain_exactly('old.srt', 'extras/trailer.mkv', 'extras')
  end

  it 'leaves candidates that have not expired alone' do
    manifest.reconcile_pending('movies/Heat (1995)', [['old.srt', 'file']])
    result = purger.run(mounted_list)
    expect(result.purged).to be_empty
    expect(File).to exist(File.join(drive_root, 'movies', 'Heat (1995)', 'old.srt'))
  end

  it 'removes a whole expired folder, its manifest row, and writes history' do
    expire('movies/Heat (1995)', [['', 'folder']])
    result = purger.run(mounted_list)

    expect(result.purged.map { |p, _| p.kind }).to eq(['folder'])
    expect(Dir).not_to exist(File.join(drive_root, 'movies', 'Heat (1995)'))
    expect(manifest.folder('movies/Heat (1995)')).to be_nil
    expect(manifest.history('movies/Heat (1995)').first).to have_attributes(event: 'removed')
    expect(manifest.history('movies/Heat (1995)').first.note).to include('backup-04-8tb', 'missing on NAS since 2026-09-01')
    expect(manifest.deletions.first.kind).to eq('folder')
  end

  it 'does nothing in dry-run mode but says what it would do' do
    expire('movies/Heat (1995)', [['old.srt', 'file']])
    result = purger.run(mounted_list, dry_run: true)
    expect(result.would_purge.map { |p, drive| [p.relative_path, drive] }).to eq([['old.srt', 'backup-04-8tb']])
    expect(result.purged).to be_empty
    expect(File).to exist(File.join(drive_root, 'movies', 'Heat (1995)', 'old.srt'))
    expect(manifest.pending_deletions.size).to eq(1)
    expect(out.string).to include('would delete movies/Heat (1995)/old.srt from backup-04-8tb')
  end

  it 'skips candidates whose drive is not mounted' do
    expire('movies/Heat (1995)', [['old.srt', 'file']])
    result = purger.run([])
    expect(result.skipped.map { |p, why| [p.relative_path, why] }).to eq([['old.srt', 'drive not mounted']])
    expect(File).to exist(File.join(drive_root, 'movies', 'Heat (1995)', 'old.srt'))
    expect(manifest.pending_deletions.size).to eq(1)
  end

  it 'refuses a path that escapes the folder' do
    expire('movies/Heat (1995)', [['../../escape', 'file']])
    write_file(File.join(mount_root, 'escape'))
    result = purger.run(mounted_list)
    expect(result.skipped.map { |_, why| why }).to eq(['path escapes its folder'])
    expect(File).to exist(File.join(mount_root, 'escape'))
  end

  it 'leaves a directory that still has content and retries next time' do
    expire('movies/Heat (1995)', [['extras', 'dir']])   # trailer.mkv inside is not a candidate
    result = purger.run(mounted_list)
    expect(result.purged).to be_empty
    expect(Dir).to exist(File.join(drive_root, 'movies', 'Heat (1995)', 'extras'))
    expect(manifest.pending_deletions.size).to eq(1)
    expect(out.string).to include('not empty yet')
  end
end
