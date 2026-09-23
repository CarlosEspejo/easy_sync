# frozen_string_literal: true

require 'json'

RSpec.describe EasySync::Jbod::Scrubber do
  let(:now) { Time.utc(2026, 9, 21, 12, 0, 0) }
  let(:clock) { double('clock', now: now) }
  let(:manifest) { memory_manifest(clock: clock) }
  let(:drives) { register_fleet(manifest).to_h { |d| [d.friendly_name, d] } }
  let(:mount_root) { File.join(temp_dir, 'Volumes') }
  let(:drive_root) { File.join(mount_root, 'backup-04-8tb') }
  let(:serial) { 'SN-backup-04-8tb' }
  let(:out) { StringIO.new }
  let(:scrubber) { described_class.new(manifest, excludes: ['.DS_Store', '#recycle'], clock: clock, out: out) }
  let(:mounted_drive) { mounted(drives['backup-04-8tb'], free: 1 * TB, mount_point: drive_root) }

  before do
    drives
    manifest.assign_folder('movies/Heat (1995)', serial)
    write_marker(drive_root, serial)
  end

  def write_marker(mount_point, serial_number)
    FileUtils.mkdir_p(File.join(mount_point, EasySync::Jbod::DRIVE_DIR))
    File.write(File.join(mount_point, EasySync::Jbod::MARKER_FILE),
               JSON.generate(serial_number: serial_number, friendly_name: 'x'))
  end

  def write(rel, content = 'sample content, sample content')
    write_file(File.join(drive_root, 'movies', 'Heat (1995)', rel), content)
  end

  def rows
    manifest.checksum_rows(serial, 'movies/Heat (1995)')
  end

  it 'gives every file a baseline on the first run, and hashes nothing new on a second run with no changes' do
    write('movie.mkv')
    write('extras/trailer.mkv')

    result = scrubber.run(mounted_drive)
    expect(result.baselined).to eq(2)
    expect(result.ok).to eq(0)
    expect(rows.map(&:digest)).to all(be_a(String))

    result2 = scrubber.run(mounted_drive)
    expect(result2.baselined).to eq(0)
    expect(result2.ok).to eq(2)
    expect(result2.changed).to eq(0)
  end

  it 'tracks only the top-level files of a root-files unit, never files in the share\'s subfolders' do
    manifest.assign_folder('movies', serial, scope: 'root')
    write_file(File.join(drive_root, 'movies', 'index.txt'), 'top level')
    write('movie.mkv')   # movies/Heat (1995)/movie.mkv belongs to the Heat folder
    scrubber.run(mounted_drive)
    expect(manifest.checksum_rows(serial, 'movies').map(&:relative_path)).to eq(['index.txt'])
    expect(rows.map(&:relative_path)).to eq(['movie.mkv'])
  end

  it 'flags rot (content changed, mtime restored) as corrupt, keeping the known-good digest' do
    path = write('movie.mkv')
    scrubber.run(mounted_drive)
    original_digest = rows.first.digest
    mtime = File.mtime(path)
    File.open(path, 'r+b') { |f| f.write('X') }   # same length: rewrite in place, no truncation
    File.utime(mtime, mtime, path)

    result = scrubber.run(mounted_drive)
    expect(result.corrupt).to eq(1)
    expect(rows.first).to have_attributes(status: 'corrupt', digest: original_digest)
  end

  it 'resets and re-baselines a file whose mtime legitimately changed, rather than flagging it corrupt' do
    path = write('movie.mkv')
    scrubber.run(mounted_drive)
    new_mtime = Time.now + 3600
    File.utime(new_mtime, new_mtime, path)

    result = scrubber.run(mounted_drive)
    expect(result.changed).to eq(1)
    expect(result.corrupt).to eq(0)
    expect(result.baselined).to eq(1)
    expect(rows.first.status).to eq('ok')
  end

  it 'removes the row for a deleted file and adds one for a new file' do
    gone = write('movie.mkv')
    write('extras/trailer.mkv')
    scrubber.run(mounted_drive)
    File.delete(gone)
    write('subs.srt')

    result = scrubber.run(mounted_drive)
    expect(result.removed).to eq(1)
    expect(rows.map(&:relative_path)).to contain_exactly('extras/trailer.mkv', 'subs.srt')
  end

  it "drops a drive's rows once the folder is reassigned off it" do
    write('movie.mkv')
    scrubber.run(mounted_drive)
    expect(rows).not_to be_empty

    manifest.reassign_folder('movies/Heat (1995)', 'SN-backup-05-8tb')
    scrubber.run(mounted_drive)
    expect(rows).to be_empty
  end

  it 'never tracks a file matching exclude_folders, and skips symlinks' do
    write('movie.mkv')
    write('.DS_Store')
    target = write('real.txt')
    File.symlink(target, File.join(drive_root, 'movies', 'Heat (1995)', 'link.txt'))

    scrubber.run(mounted_drive)
    expect(rows.map(&:relative_path)).to contain_exactly('movie.mkv', 'real.txt')
  end

  it 'Errno::EIO on a normal row marks it unreadable' do
    path = write('movie.mkv')
    scrubber.run(mounted_drive)
    allow(File).to receive(:open).and_call_original
    allow(File).to receive(:open).with(path, 'rb').and_raise(Errno::EIO)

    result = scrubber.run(mounted_drive)
    expect(result.unreadable).to eq(1)
    expect(rows.first.status).to eq('unreadable')
  end

  it 'clears the flags of a file unreadable on its very first read once a refetch makes it readable' do
    path = write('movie.mkv')
    allow(File).to receive(:open).and_call_original
    allow(File).to receive(:open).with(path, 'rb').and_raise(Errno::EIO)
    scrubber.run(mounted_drive)
    expect(rows.first).to have_attributes(status: 'unreadable', digest: nil)

    manifest.mark_refetched(serial, 'movies/Heat (1995)', ['movie.mkv'])
    allow(File).to receive(:open).with(path, 'rb').and_call_original
    result = scrubber.run(mounted_drive)
    expect(result.repaired).to eq(1)
    expect(rows.first).to have_attributes(status: 'ok', refetched_at: nil, failed_at: nil)
    expect(rows.first.digest).to be_a(String)
    expect(manifest.scrub_findings).to be_empty
  end

  it 'leaves every row alone when a folder cannot be walked completely' do
    write('movie.mkv')
    write('extras/trailer.mkv')
    scrubber.run(mounted_drive)
    before_dump = manifest.db.execute('SELECT * FROM file_checksums ORDER BY relative_path')

    allow(Find).to receive(:find).and_raise(Errno::EIO)
    scrubber.run(mounted_drive)
    expect(manifest.db.execute('SELECT * FROM file_checksums ORDER BY relative_path').map { |r| r['relative_path'] })
      .to eq(before_dump.map { |r| r['relative_path'] })
    expect(out.string).to include('could not walk it completely')
  end

  it 'does not flag a file whose read failed because the drive was unplugged mid-read' do
    path = write('movie.mkv')
    scrubber.run(mounted_drive)
    marker = File.join(drive_root, EasySync::Jbod::MARKER_FILE)
    allow(File).to receive(:open).and_call_original
    allow(File).to receive(:open).with(path, 'rb') do
      File.delete(marker)
      raise Errno::EIO
    end

    result = scrubber.run(mounted_drive)
    expect(result.stopped_reason).to eq(:unmounted)
    expect(result.unreadable).to eq(0)
    expect(rows.first.status).to eq('ok')
  end

  describe 'refetched rows (sync repaired a flagged file)' do
    let(:original_content) { 'sample content, sample content' }
    let(:path) { File.join(drive_root, 'movies', 'Heat (1995)', 'movie.mkv') }

    before do
      write('movie.mkv', original_content)
      scrubber.run(mounted_drive)   # baseline
      mtime = File.mtime(path)
      File.open(path, 'r+b') { |f| f.write('X') }
      File.utime(mtime, mtime, path)
      scrubber.run(mounted_drive)   # -> corrupt
      expect(rows.first.status).to eq('corrupt')
      manifest.mark_refetched(serial, 'movies/Heat (1995)', ['movie.mkv'])
    end

    it 'goes back to ok once the refetched file matches its baseline' do
      good = rows.first
      File.write(path, original_content)
      File.utime(Time.at(good.mtime), Time.at(good.mtime), path)

      result = scrubber.run(mounted_drive)
      expect(result.repaired).to eq(1)
      expect(rows.first).to have_attributes(status: 'ok', refetched_at: nil, failed_at: nil)
    end

    it 'goes to unresolved, and is never refetched again automatically, when it still does not match' do
      result = scrubber.run(mounted_drive)   # still corrupted content, refetched_at was set but bytes unchanged
      expect(result.unresolved).to eq(1)
      expect(rows.first.status).to eq('unresolved')
      expect(manifest.flagged_checksums(serial, 'movies/Heat (1995)')).to be_empty
    end
  end

  describe 'the deadline' do
    it 'stops before starting the next file once passed, and a later run picks up the file that was skipped first' do
      write('a.mkv', 'aaa')
      write('b.mkv', 'bbb')
      scrubber.run(mounted_drive)   # baseline both, unconstrained
      verified_before = rows.to_h { |r| [r.relative_path, r.verified_at] }

      t = now
      ticking = double('clock')
      allow(ticking).to receive(:now) { t += 1 }
      # ticking.now ticks once for #run's own "started" timestamp, once for
      # last_commit's initial read, then once per row checked: now+3 for row
      # 1 (before the deadline), now+4 for row 2 (at/after it), so exactly
      # one file is processed this run.
      scrubber2 = described_class.new(manifest, excludes: [], clock: ticking, out: out, deadline: now + 3.5)
      result = scrubber2.run(mounted_drive)

      expect(result.stopped_reason).to eq(:deadline)
      expect(result.ok).to eq(1)
      reprocessed = rows.select { |r| r.verified_at != verified_before[r.relative_path] }
      expect(reprocessed.size).to eq(1)
      skipped = (rows.map(&:relative_path) - reprocessed.map(&:relative_path)).first

      # a later, unconstrained run (a fresh `scrub` invocation) re-verifies
      # oldest-verified-first, so the file skipped above is processed first.
      order = []
      allow(manifest).to receive(:checksum_hashed).and_wrap_original do |m, *args, **kwargs|
        order << args[2]
        m.call(*args, **kwargs)
      end
      scrubber.run(mounted_drive)
      expect(order.first).to eq(skipped)
    end
  end

  it 'prints a progress line once per commit interval' do
    write('a.mkv', 'aaa')
    write('b.mkv', 'bbb')
    write('c.mkv', 'ccc')

    t = now
    ticking = double('clock')
    allow(ticking).to receive(:now) { t += 16 }
    # started, last_commit, then one tick per row (+16 each): row 2's tick is
    # 32s past last_commit, crossing COMMIT_INTERVAL (30s) exactly once.
    scrubber2 = described_class.new(manifest, excludes: [], clock: ticking, out: out)
    scrubber2.run(mounted_drive)

    expect(out.string.lines.grep(%r{backup-04-8tb: 2/3 files, .* of .* \(\d+%\), [\d.]+ MB/s, ETA .*}).size).to eq(1)
  end

  describe 'batched writes (Jbod::ScrubPool runs several of these against one manifest at once)' do
    it 'flushes at each commit interval crossed, and once more at the end' do
      write('a.mkv', 'aaa')
      write('b.mkv', 'bbb')
      write('c.mkv', 'ccc')

      t = now
      ticking = double('clock')
      allow(ticking).to receive(:now) { t += 16 }
      # started, last_commit, then one tick per row (+16 each): row 2's tick is
      # 32s past last_commit, crossing COMMIT_INTERVAL (30s) exactly once, so
      # one mid-run flush plus the final one in the ensure.
      scrubber2 = described_class.new(manifest, excludes: [], clock: ticking, out: out)
      flushes = 0
      allow(manifest.db).to receive(:transaction).with(:immediate).and_wrap_original do |m, *args, &blk|
        flushes += 1
        m.call(*args, &blk)
      end

      scrubber2.run(mounted_drive)
      # +1 for the walk phase's own reconcile_checksums transaction.
      expect(flushes).to eq(3)
      expect(rows.map(&:digest)).to all(be_a(String))
    end

    it 'flushes hash outcomes exactly once, at the end, when the clock never crosses the commit interval' do
      write('a.mkv', 'aaa')
      flushes = 0
      allow(manifest.db).to receive(:transaction).with(:immediate).and_wrap_original do |m, *args, &blk|
        flushes += 1
        m.call(*args, &blk)
      end

      scrubber.run(mounted_drive)
      # +1 for the walk phase's own reconcile_checksums transaction.
      expect(flushes).to eq(2)
    end

    it 'flushes files completed before an Interrupt, leaving the interrupted file untouched' do
      write('a.mkv', 'aaa')
      path_b = write('b.mkv', 'bbb')
      write('c.mkv', 'ccc')
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(path_b, 'rb').and_raise(Interrupt)

      expect { scrubber.run(mounted_drive) }.to raise_error(Interrupt)
      by_path = rows.to_h { |r| [r.relative_path, r.digest] }
      expect(by_path['a.mkv']).to be_a(String)
      expect(by_path['b.mkv']).to be_nil
      expect(by_path['c.mkv']).to be_nil
    end
  end

  it 'stops mid-run when the drive marker disappears, and does not touch the row about to be processed' do
    write('a.mkv', 'aaa')
    write('b.mkv', 'bbb')
    scrubber.run(mounted_drive)
    verified_before = rows.map(&:verified_at)

    File.delete(File.join(drive_root, EasySync::Jbod::MARKER_FILE))

    result = scrubber.run(mounted_drive)
    expect(result.stopped_reason).to eq(:unmounted)
    expect(result.ok).to eq(0)
    expect(rows.map(&:verified_at)).to eq(verified_before)
  end

  describe 'dry run' do
    it 'reports what it would do and leaves the manifest completely unchanged' do
      write('movie.mkv')
      scrubber.run(mounted_drive)   # establish a real baseline first
      before_dump = manifest.db.execute('SELECT * FROM file_checksums ORDER BY relative_path')

      write('new_file.mkv')
      dry_scrubber = described_class.new(manifest, excludes: [], clock: clock, out: out, dry_run: true)
      result = dry_scrubber.run(mounted_drive)

      after_dump = manifest.db.execute('SELECT * FROM file_checksums ORDER BY relative_path')
      expect(after_dump).to eq(before_dump)
      expect(result.stopped_reason).to be_nil
      expect(out.string).to include('DRY RUN')
    end
  end
end
