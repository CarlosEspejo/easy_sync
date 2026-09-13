# frozen_string_literal: true

RSpec.describe EasySync::Jbod::Manifest do
  let(:clock) { double('clock', now: Time.utc(2026, 9, 13, 12, 0, 0)) }
  let(:manifest) { memory_manifest(clock: clock) }

  describe 'schema' do
    it 'creates the tables and stamps the schema version' do
      tables = manifest.db.execute("SELECT name FROM sqlite_master WHERE type='table'").map { |r| r['name'] }
      expect(tables).to include('drives', 'folders', 'placement_history', 'sync_runs')
      expect(manifest.schema_version).to eq(described_class::SCHEMA_VERSION)
    end

    it 'is idempotent when reopened on the same database' do
      db = manifest.db
      expect { described_class.new(db) }.not_to raise_error
    end

    it 'persists to a file via .open' do
      path = File.join(temp_dir, 'nested', 'manifest.sqlite3')
      m = described_class.open(path)
      m.register_drive(serial_number: 'A', friendly_name: 'backup-01-3tb', capacity_bytes: 3 * TB)
      m.close
      expect(described_class.open(path).drives.map(&:friendly_name)).to eq(['backup-01-3tb'])
    end
  end

  describe '#register_drive' do
    it 'stores a drive keyed by serial number' do
      drive = manifest.register_drive(serial_number: 'SN1', friendly_name: 'backup-01-3tb',
                                      capacity_bytes: 3 * TB, volume_uuid: 'UUID-1')
      expect(drive).to have_attributes(serial_number: 'SN1', friendly_name: 'backup-01-3tb',
                                       capacity_bytes: 3 * TB, volume_uuid: 'UUID-1',
                                       added_date: '2026-09-13T12:00:00Z')
    end

    it 'rejects a duplicate serial number' do
      manifest.register_drive(serial_number: 'SN1', friendly_name: 'a', capacity_bytes: 1)
      expect { manifest.register_drive(serial_number: 'SN1', friendly_name: 'b', capacity_bytes: 1) }
        .to raise_error(SQLite3::ConstraintException)
    end

    it 'rejects a duplicate friendly name' do
      manifest.register_drive(serial_number: 'SN1', friendly_name: 'a', capacity_bytes: 1)
      expect { manifest.register_drive(serial_number: 'SN2', friendly_name: 'a', capacity_bytes: 1) }
        .to raise_error(SQLite3::ConstraintException)
    end

    it 'finds drives by serial or by name' do
      register_fleet(manifest)
      expect(manifest.drive('SN-backup-04-8tb').friendly_name).to eq('backup-04-8tb')
      expect(manifest.drive_by_name('backup-04-8tb').serial_number).to eq('SN-backup-04-8tb')
      expect(manifest.drive('nope')).to be_nil
    end
  end

  describe '#update_drive_usage' do
    before { register_fleet(manifest) }

    it 'records last seen usage numbers' do
      drive = manifest.update_drive_usage('SN-backup-01-3tb', used_bytes: 100, free_bytes: 900)
      expect(drive).to have_attributes(last_used_bytes: 100, last_free_bytes: 900,
                                       last_seen_at: '2026-09-13T12:00:00Z')
    end

    it 'keeps the registered capacity unless a new one is given' do
      manifest.update_drive_usage('SN-backup-01-3tb', used_bytes: 1, free_bytes: 1)
      expect(manifest.drive('SN-backup-01-3tb').capacity_bytes).to eq(3 * TB)
      manifest.update_drive_usage('SN-backup-01-3tb', used_bytes: 1, free_bytes: 1, capacity_bytes: 42)
      expect(manifest.drive('SN-backup-01-3tb').capacity_bytes).to eq(42)
    end

    it 'raises for an unknown drive' do
      expect { manifest.update_drive_usage('nope', used_bytes: 1, free_bytes: 1) }
        .to raise_error(described_class::UnknownDrive)
    end
  end

  describe 'folder assignment' do
    before { register_fleet(manifest) }

    it 'assigns a folder and writes an "assigned" history row' do
      folder = manifest.assign_folder('Photos', 'SN-backup-04-8tb', size_bytes: 500, note: 'first')
      expect(folder).to have_attributes(folder_path: 'Photos', drive_serial: 'SN-backup-04-8tb', size_bytes: 500,
                                        assigned_at: '2026-09-13T12:00:00Z', last_synced_at: nil)
      expect(manifest.history('Photos').map { |e| [e.event, e.drive_serial, e.note] })
        .to eq([['assigned', 'SN-backup-04-8tb', 'first']])
    end

    it 'refuses to assign a folder twice' do
      manifest.assign_folder('Photos', 'SN-backup-04-8tb')
      expect { manifest.assign_folder('Photos', 'SN-backup-05-8tb') }.to raise_error(described_class::DuplicateFolder)
    end

    it 'refuses to assign to an unregistered drive' do
      expect { manifest.assign_folder('Photos', 'ghost') }.to raise_error(described_class::UnknownDrive)
    end

    it 'lists folders per drive' do
      manifest.assign_folder('Photos', 'SN-backup-04-8tb')
      manifest.assign_folder('Music', 'SN-backup-04-8tb')
      manifest.assign_folder('Docs', 'SN-backup-01-3tb')
      expect(manifest.folders_on('SN-backup-04-8tb').map(&:folder_path)).to eq(%w[Music Photos])
      expect(manifest.folders.map(&:folder_path)).to eq(%w[Docs Music Photos])
    end
  end

  describe '#reassign_folder' do
    before do
      register_fleet(manifest)
      manifest.assign_folder('Photos', 'SN-backup-04-8tb')
      manifest.record_sync(folder_path: 'Photos', drive_serial: 'SN-backup-04-8tb', started_at: 't0',
                           finished_at: 't1', exit_status: 0)
    end

    it 'moves the record, clears sync state, and keeps the old home in history' do
      folder = manifest.reassign_folder('Photos', 'SN-backup-07-8tb', note: 'moved by hand')
      expect(folder).to have_attributes(drive_serial: 'SN-backup-07-8tb', last_synced_at: nil, last_sync_status: nil)
      expect(manifest.history('Photos').map { |e| [e.event, e.drive_serial] })
        .to eq([%w[reassigned SN-backup-07-8tb], %w[assigned SN-backup-04-8tb]])
    end

    it 'answers "where did this used to live"' do
      manifest.reassign_folder('Photos', 'SN-backup-07-8tb')
      manifest.reassign_folder('Photos', 'SN-backup-02-6tb')
      expect(manifest.history('Photos').map(&:drive_serial))
        .to eq(%w[SN-backup-02-6tb SN-backup-07-8tb SN-backup-04-8tb])
    end

    it 'is a no-op when the drive is unchanged' do
      manifest.reassign_folder('Photos', 'SN-backup-04-8tb')
      expect(manifest.history('Photos').size).to eq(1)
      expect(manifest.folder('Photos').last_sync_status).to eq('ok')
    end

    it 'raises for an unknown folder' do
      expect { manifest.reassign_folder('Nope', 'SN-backup-04-8tb') }.to raise_error(described_class::UnknownFolder)
    end
  end

  describe '#remove_folder' do
    it 'deletes the row but keeps the history' do
      register_fleet(manifest)
      manifest.assign_folder('Photos', 'SN-backup-04-8tb')
      manifest.remove_folder('Photos', note: 'deleted on NAS')
      expect(manifest.folder('Photos')).to be_nil
      expect(manifest.history('Photos').map(&:event)).to eq(%w[removed assigned])
    end
  end

  describe '#record_sync' do
    before do
      register_fleet(manifest)
      manifest.assign_folder('Photos', 'SN-backup-04-8tb', size_bytes: 10)
    end

    it 'stores the run and updates the folder on success' do
      folder = manifest.record_sync(folder_path: 'Photos', drive_serial: 'SN-backup-04-8tb',
                                    started_at: '2026-09-13T12:00:00Z', finished_at: '2026-09-13T12:05:00Z',
                                    exit_status: 0, bytes_transferred: 5, total_size_bytes: 999)
      expect(folder).to have_attributes(last_synced_at: '2026-09-13T12:05:00Z', last_sync_status: 'ok',
                                        size_bytes: 999)
      expect(manifest.sync_runs(folder_path: 'Photos').first)
        .to have_attributes(exit_status: 0, bytes_transferred: 5, total_size_bytes: 999)
    end

    it 'marks failure without touching last_synced_at or size' do
      folder = manifest.record_sync(folder_path: 'Photos', drive_serial: 'SN-backup-04-8tb',
                                    started_at: 't0', finished_at: 't1', exit_status: 23, total_size_bytes: 999)
      expect(folder).to have_attributes(last_synced_at: nil, last_sync_status: 'failed', size_bytes: 10)
    end

    it 'keeps the previous size when rsync stats are missing' do
      manifest.record_sync(folder_path: 'Photos', drive_serial: 'SN-backup-04-8tb',
                           started_at: 't0', finished_at: 't1', exit_status: 0)
      expect(manifest.folder('Photos').size_bytes).to eq(10)
    end

    it 'returns runs newest first with a limit' do
      3.times do |i|
        manifest.record_sync(folder_path: 'Photos', drive_serial: 'SN-backup-04-8tb',
                             started_at: "t#{i}", finished_at: "t#{i}", exit_status: 0)
      end
      expect(manifest.sync_runs(limit: 2).map(&:started_at)).to eq(%w[t2 t1])
    end
  end
end

RSpec.describe EasySync::Jbod::Manifest, 'pending deletions' do
  let(:clock) { double('clock', now: Time.utc(2026, 9, 13, 12, 0, 0)) }
  let(:manifest) { memory_manifest(clock: clock) }

  before do
    register_fleet(manifest)
    manifest.assign_folder('movies/Heat (1995)', 'SN-backup-04-8tb')
  end

  describe '#reconcile_pending' do
    it 'records newly missing paths with the run time' do
      counts = manifest.reconcile_pending('movies/Heat (1995)', [['extras', 'dir'], ['extras/trailer.mkv', 'file']])
      expect(counts).to eq(new: 2, still: 0, reappeared: 0)
      expect(manifest.pending_deletions.map { |p| [p.relative_path, p.kind, p.first_missing_at, p.missing_runs] })
        .to eq([['extras', 'dir', '2026-09-13T12:00:00Z', 1], ['extras/trailer.mkv', 'file', '2026-09-13T12:00:00Z', 1]])
    end

    it 'keeps first_missing_at and bumps the run counter for paths still missing' do
      manifest.reconcile_pending('movies/Heat (1995)', [['a.srt', 'file']], at: '2026-09-01T00:00:00Z')
      counts = manifest.reconcile_pending('movies/Heat (1995)', [['a.srt', 'file'], ['b.srt', 'file']])
      expect(counts).to eq(new: 1, still: 1, reappeared: 0)
      a, b = manifest.pending_deletions
      expect(a).to have_attributes(relative_path: 'a.srt', first_missing_at: '2026-09-01T00:00:00Z',
                                   last_missing_at: '2026-09-13T12:00:00Z', missing_runs: 2)
      expect(b).to have_attributes(relative_path: 'b.srt', missing_runs: 1)
    end

    it 'forgets paths that reappeared on the NAS so their clock restarts' do
      manifest.reconcile_pending('movies/Heat (1995)', [['a.srt', 'file']], at: '2026-09-01T00:00:00Z')
      counts = manifest.reconcile_pending('movies/Heat (1995)', [])
      expect(counts).to eq(new: 0, still: 0, reappeared: 1)
      expect(manifest.pending_deletions).to be_empty
      manifest.reconcile_pending('movies/Heat (1995)', [['a.srt', 'file']])
      expect(manifest.pending_deletions.first.first_missing_at).to eq('2026-09-13T12:00:00Z')
    end

    it 'scopes reconciliation to one folder' do
      manifest.assign_folder('photos', 'SN-backup-01-3tb')
      manifest.reconcile_pending('photos', [['x.jpg', 'file']])
      manifest.reconcile_pending('movies/Heat (1995)', [])
      expect(manifest.pending_deletions.map(&:folder_path)).to eq(['photos'])
      expect(manifest.pending_deletions(folder_path: 'movies/Heat (1995)')).to be_empty
    end

    it 'tracks a whole missing folder with an empty relative path' do
      manifest.reconcile_pending('movies/Heat (1995)', [['', 'folder']])
      expect(manifest.pending_deletions.first).to have_attributes(relative_path: '', kind: 'folder')
      expect(manifest.pending_deletions.first).to be_whole_folder
    end
  end

  describe '#expired_deletions' do
    it 'requires both the day and run thresholds' do
      manifest.reconcile_pending('movies/Heat (1995)', [['old.srt', 'file'], ['fresh.srt', 'file']], at: '2026-09-01T00:00:00Z')
      manifest.reconcile_pending('movies/Heat (1995)', [['old.srt', 'file'], ['fresh.srt', 'file'], ['once.srt', 'file']],
                                 at: '2026-09-10T00:00:00Z')
      manifest.db.execute("UPDATE pending_deletions SET first_missing_at = '2026-09-12T00:00:00Z' WHERE relative_path = 'fresh.srt'")

      expired = manifest.expired_deletions(now: Time.utc(2026, 9, 13), grace_days: 7, grace_runs: 2)
      expect(expired.map(&:relative_path)).to eq(['old.srt'])   # fresh.srt: too recent; once.srt: only 1 run
    end

    it 'exposes the expiry date' do
      manifest.reconcile_pending('movies/Heat (1995)', [['a', 'file']], at: '2026-09-01T00:00:00Z')
      expect(manifest.pending_deletions.first.expires_at(7)).to eq(Time.utc(2026, 9, 8))
    end
  end

  describe '#record_deletion' do
    it 'moves the candidate into the audit log' do
      manifest.reconcile_pending('movies/Heat (1995)', [['a.srt', 'file']], at: '2026-09-01T00:00:00Z')
      manifest.record_deletion(manifest.pending_deletions.first, drive_serial: 'SN-backup-04-8tb')
      expect(manifest.pending_deletions).to be_empty
      expect(manifest.deletions.first).to have_attributes(folder_path: 'movies/Heat (1995)', relative_path: 'a.srt',
                                                          kind: 'file', drive_serial: 'SN-backup-04-8tb',
                                                          first_missing_at: '2026-09-01T00:00:00Z',
                                                          deleted_at: '2026-09-13T12:00:00Z')
    end
  end

  it 'migrates a version 1 database by adding the new tables' do
    db = SQLite3::Database.new(':memory:')
    db.execute('PRAGMA user_version = 1')
    m = described_class.new(db)
    expect(m.schema_version).to eq(2)
    expect(m.pending_deletions).to eq([])
  end
end
