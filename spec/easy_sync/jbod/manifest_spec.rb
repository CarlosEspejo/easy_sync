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

    it 'writes a consistent copy of itself with #backup_to' do
      manifest.register_drive(serial_number: 'A', friendly_name: 'backup-01-3tb', capacity_bytes: 3 * TB)
      path = File.join(temp_dir, 'copy', 'manifest.sqlite3')
      manifest.backup_to(path)
      expect(described_class.open(path).drives.map(&:serial_number)).to eq(['A'])
      expect(Dir.children(File.dirname(path))).to eq(['manifest.sqlite3'])   # no .tmp left behind
    end

    it 'persists to a file via .open' do
      path = File.join(temp_dir, 'nested', 'manifest.sqlite3')
      m = described_class.open(path)
      m.register_drive(serial_number: 'A', friendly_name: 'backup-01-3tb', capacity_bytes: 3 * TB)
      m.close
      expect(described_class.open(path).drives.map(&:friendly_name)).to eq(['backup-01-3tb'])
    end

    it 'upgrades a real schema-v1 database (drives table with no model column) in place' do
      db = SQLite3::Database.new(':memory:')
      db.execute_batch(<<~SQL)
        CREATE TABLE drives (
          serial_number   TEXT PRIMARY KEY,
          friendly_name   TEXT NOT NULL UNIQUE,
          capacity_bytes  INTEGER NOT NULL,
          added_date      TEXT NOT NULL,
          volume_uuid     TEXT,
          last_seen_at    TEXT,
          last_used_bytes INTEGER,
          last_free_bytes INTEGER,
          smart_status    TEXT,
          smart_detail    TEXT,
          smart_checked_at TEXT,
          retired_at      TEXT
        );
      SQL
      db.execute("INSERT INTO drives (serial_number, friendly_name, capacity_bytes, added_date) VALUES ('SN1', 'backup-01-3tb', ?, '2026-01-01T00:00:00Z')",
                 [3 * TB])
      db.execute('PRAGMA user_version = 1')

      m = described_class.new(db, clock: clock)
      expect(m.schema_version).to eq(described_class::SCHEMA_VERSION)
      expect(m.drives.first).to have_attributes(serial_number: 'SN1', friendly_name: 'backup-01-3tb', model: nil,
                                                power_on_hours: nil)
      expect(m.update_drive_health('SN1', status: 'ok', detail: 'PASSED', power_on_hours: 500).power_on_hours).to eq(500)
    end

    it 'still adds the model column when a pre-2.0 build stamped the database user_version 5 (the real manifest)' do
      db = SQLite3::Database.new(':memory:')
      db.execute('CREATE TABLE drives (serial_number TEXT PRIMARY KEY, friendly_name TEXT NOT NULL UNIQUE, ' \
                 'capacity_bytes INTEGER NOT NULL, added_date TEXT NOT NULL, volume_uuid TEXT, last_seen_at TEXT, ' \
                 'last_used_bytes INTEGER, last_free_bytes INTEGER, smart_status TEXT, smart_detail TEXT, ' \
                 'smart_checked_at TEXT, retired_at TEXT)')
      db.execute("INSERT INTO drives (serial_number, friendly_name, capacity_bytes, added_date) VALUES ('SN1', 'a', 1, 'x')")
      db.execute('PRAGMA user_version = 5')

      m = described_class.new(db, clock: clock)
      expect(m.update_drive_model('SN1', model: 'WDC WD80EFZZ').model).to eq('WDC WD80EFZZ')
      expect(m.schema_version).to eq(5)   # never stamped downward
      expect { described_class.new(db, clock: clock) }.not_to raise_error   # reopening is a no-op
    end
  end

  describe '#register_drive' do
    it 'stores a drive keyed by serial number' do
      drive = manifest.register_drive(serial_number: 'SN1', friendly_name: 'backup-01-3tb',
                                      capacity_bytes: 3 * TB, volume_uuid: 'UUID-1', model: 'WDC WD80EFZZ-68BTXN0')
      expect(drive).to have_attributes(serial_number: 'SN1', friendly_name: 'backup-01-3tb',
                                       capacity_bytes: 3 * TB, volume_uuid: 'UUID-1',
                                       model: 'WDC WD80EFZZ-68BTXN0',
                                       added_date: '2026-09-13T12:00:00Z')
    end

    it 'defaults model to nil when the enclosure hides it' do
      drive = manifest.register_drive(serial_number: 'SN1', friendly_name: 'backup-01-3tb', capacity_bytes: 3 * TB)
      expect(drive.model).to be_nil
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

  describe '#rename_drive' do
    it 'relabels a drive by serial' do
      manifest.register_drive(serial_number: 'SN1', friendly_name: 'old-name', capacity_bytes: 3 * TB)
      drive = manifest.rename_drive('SN1', 'new-name')
      expect(drive.friendly_name).to eq('new-name')
      expect(manifest.drive_by_name('new-name').serial_number).to eq('SN1')
      expect(manifest.drive_by_name('old-name')).to be_nil
    end

    it 'rejects an unknown serial' do
      expect { manifest.rename_drive('nope', 'x') }.to raise_error(described_class::UnknownDrive)
    end

    it 'rejects a name already taken by another drive (use #swap_drive_names for that)' do
      manifest.register_drive(serial_number: 'SN1', friendly_name: 'a', capacity_bytes: 1)
      manifest.register_drive(serial_number: 'SN2', friendly_name: 'b', capacity_bytes: 1)
      expect { manifest.rename_drive('SN1', 'b') }.to raise_error(SQLite3::ConstraintException)
      expect(manifest.drive('SN1').friendly_name).to eq('a')   # untouched by the failed attempt
    end
  end

  describe '#swap_drive_names' do
    it 'exchanges two names without a UNIQUE collision in between' do
      manifest.register_drive(serial_number: 'SN1', friendly_name: 'backup-07-2tb', capacity_bytes: 2 * TB)
      manifest.register_drive(serial_number: 'SN2', friendly_name: 'backup-08-6tb', capacity_bytes: 6 * TB)

      a, b = manifest.swap_drive_names('SN1', 'SN2')
      expect(a).to have_attributes(serial_number: 'SN1', friendly_name: 'backup-08-6tb')
      expect(b).to have_attributes(serial_number: 'SN2', friendly_name: 'backup-07-2tb')
      expect(manifest.drive_by_name('backup-07-2tb').serial_number).to eq('SN2')
      expect(manifest.drive_by_name('backup-08-6tb').serial_number).to eq('SN1')
      # no leftover temp name
      expect(manifest.drives.map(&:friendly_name)).to contain_exactly('backup-07-2tb', 'backup-08-6tb')
    end

    it 'rejects an unknown serial on either side, leaving both names untouched' do
      manifest.register_drive(serial_number: 'SN1', friendly_name: 'a', capacity_bytes: 1)
      expect { manifest.swap_drive_names('SN1', 'nope') }.to raise_error(described_class::UnknownDrive)
      expect(manifest.drive('SN1').friendly_name).to eq('a')
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

  describe '#update_drive_health' do
    before { register_fleet(manifest) }

    it 'records the SMART status, detail, and power-on hours' do
      drive = manifest.update_drive_health('SN-backup-01-3tb', status: 'ok', detail: 'PASSED', power_on_hours: 10_432)
      expect(drive).to have_attributes(smart_status: 'ok', smart_detail: 'PASSED', power_on_hours: 10_432)
    end

    it 'keeps the last known power-on hours when a health source has none to report' do
      manifest.update_drive_health('SN-backup-01-3tb', status: 'ok', detail: 'PASSED', power_on_hours: 10_432)
      drive = manifest.update_drive_health('SN-backup-01-3tb', status: 'ok', detail: 'diskutil: Verified')
      expect(drive.power_on_hours).to eq(10_432)
    end
  end

  describe 'SMART reallocated-sector trend' do
    before { register_fleet(manifest) }

    it 'has no baseline before any check is recorded' do
      expect(manifest.reallocated_baseline('SN-backup-01-3tb')).to be_nil
    end

    it 'uses the first-ever recorded check as the baseline until something is verified' do
      manifest.record_smart_check('SN-backup-01-3tb', reallocated_sector_ct: 24)
      manifest.record_smart_check('SN-backup-01-3tb', reallocated_sector_ct: 24)
      expect(manifest.reallocated_baseline('SN-backup-01-3tb')).to eq(24)
    end

    it 'raises when verifying a drive with no SMART check recorded yet' do
      expect { manifest.verify_drive_stable('SN-backup-01-3tb') }.to raise_error(EasySync::Error, /no SMART check/)
    end

    it 'moves the baseline to a verified checkpoint, overriding the first-ever value' do
      manifest.record_smart_check('SN-backup-01-3tb', reallocated_sector_ct: 24)
      manifest.record_smart_check('SN-backup-01-3tb', reallocated_sector_ct: 24)
      manifest.verify_drive_stable('SN-backup-01-3tb', note: 'SpinRite Level 3, 0 new defects')
      expect(manifest.reallocated_baseline('SN-backup-01-3tb')).to eq(24)

      latest = manifest.latest_smart_check('SN-backup-01-3tb')
      expect(latest).to include('verified' => 1, 'note' => 'SpinRite Level 3, 0 new defects', 'reallocated_sector_ct' => 24)
    end

    it 'keeps different drives on independent baselines' do
      manifest.record_smart_check('SN-backup-01-3tb', reallocated_sector_ct: 24)
      manifest.record_smart_check('SN-backup-04-8tb', reallocated_sector_ct: 0)
      expect(manifest.reallocated_baseline('SN-backup-01-3tb')).to eq(24)
      expect(manifest.reallocated_baseline('SN-backup-04-8tb')).to eq(0)
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

    it 'schedules the old drive copy for cleanup' do
      manifest.reassign_folder('Photos', 'SN-backup-07-8tb')
      pending = manifest.pending_deletions(folder_path: 'Photos').first
      expect(pending).to have_attributes(cause: 'reassigned', drive_serial: 'SN-backup-04-8tb', kind: 'folder')
      expect(pending).to be_whole_folder
      expect(pending).to be_reassigned
    end

    it 'does not schedule cleanup when schedule_cleanup: false' do
      manifest.reassign_folder('Photos', 'SN-backup-07-8tb', schedule_cleanup: false)
      expect(manifest.pending_deletions(folder_path: 'Photos')).to be_empty
    end

    it 'schedules a distinct cleanup row for each drive a folder passes through' do
      manifest.reassign_folder('Photos', 'SN-backup-07-8tb')
      manifest.reassign_folder('Photos', 'SN-backup-02-6tb')
      expect(manifest.pending_deletions(folder_path: 'Photos').map(&:drive_serial))
        .to contain_exactly('SN-backup-04-8tb', 'SN-backup-07-8tb')
    end

    it 'does not schedule cleanup for a no-op reassign to the same drive' do
      manifest.reassign_folder('Photos', 'SN-backup-04-8tb')
      expect(manifest.pending_deletions(folder_path: 'Photos')).to be_empty
    end
  end

  describe '#move_all_folders' do
    it 'does not schedule old-drive cleanup when handing folders to a new drive (replace-drive retires the old one instead)' do
      register_fleet(manifest)
      manifest.assign_folder('Photos', 'SN-backup-04-8tb')
      manifest.move_all_folders('SN-backup-04-8tb', 'SN-backup-07-8tb', note: 'replaced')
      expect(manifest.folder('Photos').drive_serial).to eq('SN-backup-07-8tb')
      expect(manifest.pending_deletions(folder_path: 'Photos')).to be_empty
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

  describe '#sync_runs_since' do
    before { register_fleet(manifest) }

    it 'returns every successful run at or after the given time, oldest first, with no limit' do
      manifest.assign_folder('Photos', 'SN-backup-04-8tb', size_bytes: 10)
      manifest.record_sync(folder_path: 'Photos', drive_serial: 'SN-backup-04-8tb',
                           started_at: '2026-09-15T07:00:00Z', finished_at: '2026-09-15T07:00:01Z', exit_status: 0)
      manifest.record_sync(folder_path: 'Photos', drive_serial: 'SN-backup-04-8tb',
                           started_at: '2026-09-15T09:00:00Z', finished_at: '2026-09-15T09:00:01Z', exit_status: 23)
      base = Time.utc(2026, 9, 15, 8, 0, 0)
      101.times do |i|
        manifest.assign_folder("Movies/#{i}", 'SN-backup-04-8tb', size_bytes: 1)
        manifest.record_sync(folder_path: "Movies/#{i}", drive_serial: 'SN-backup-04-8tb',
                             started_at: (base + i).iso8601, finished_at: 't1', exit_status: 0)
      end

      runs = manifest.sync_runs_since(base.iso8601)
      expect(runs.size).to eq(101)   # excludes the 07:00 run (too early) and the 09:00 one (failed)
      expect(runs.first.started_at).to eq(base.iso8601)
    end
  end
end

RSpec.describe EasySync::Jbod::Manifest, 'source inventory' do
  let(:clock) { double('clock', now: Time.utc(2026, 9, 13, 12, 0, 0)) }
  let(:manifest) { memory_manifest(clock: clock) }

  it 'replaces the inventory wholesale and reads it back with the share' do
    manifest.replace_source_inventory([{ folder_path: 'movies/A', size_bytes: 10, state: 'placed', detail: 'on x' },
                                       { folder_path: 'movies/B', size_bytes: 20, state: 'unplaced', detail: 'no drive has room' }])
    manifest.replace_source_inventory([{ folder_path: 'tv/C', size_bytes: 0, state: 'empty', detail: 'no real files' }])
    inv = manifest.source_inventory
    expect(inv.map(&:folder_path)).to eq(['tv/C'])
    expect(inv.first).to have_attributes(share: 'tv', state: 'empty', seen_at: '2026-09-13T12:00:00Z')
    expect(manifest.schema_version).to eq(described_class::SCHEMA_VERSION)
  end
end

RSpec.describe EasySync::Jbod::Manifest, 'retiring drives' do
  let(:clock) { double('clock', now: Time.utc(2026, 9, 13, 12, 0, 0)) }
  let(:manifest) { memory_manifest(clock: clock) }

  before do
    register_fleet(manifest)
    manifest.assign_folder('movies/A', 'SN-backup-04-8tb')
    manifest.assign_folder('movies/B', 'SN-backup-04-8tb')
    manifest.assign_folder('photos', 'SN-backup-01-3tb')
    manifest.reconcile_pending('movies/A', [['old.srt', 'file']])
  end

  it 'hides a retired drive from #drives unless asked, keeping its row' do
    manifest.retire_drive('SN-backup-04-8tb')
    expect(manifest.drives.map(&:friendly_name)).not_to include('backup-04-8tb')
    expect(manifest.drives(include_retired: true).map(&:friendly_name)).to include('backup-04-8tb')
    expect(manifest.drive('SN-backup-04-8tb')).to have_attributes(retired_at: '2026-09-13T12:00:00Z')
    expect(manifest.drive('SN-backup-04-8tb')).to be_retired
  end

  it 'moves every folder of a drive to another, recording each' do
    moved = manifest.move_all_folders('SN-backup-04-8tb', 'SN-backup-07-8tb', note: 'replaced')
    expect(moved).to eq(['movies/A', 'movies/B'])
    expect(manifest.folders_on('SN-backup-04-8tb')).to be_empty
    expect(manifest.folders_on('SN-backup-07-8tb').map(&:folder_path)).to eq(['movies/A', 'movies/B'])
    expect(manifest.folder('photos').drive_serial).to eq('SN-backup-01-3tb')
    expect(manifest.history('movies/A').first).to have_attributes(event: 'reassigned', drive_serial: 'SN-backup-07-8tb', note: 'replaced')
  end

  it 'forgets every folder of a drive when there is no replacement, so they are placed afresh' do
    manifest.move_all_folders('SN-backup-04-8tb', nil, note: 'retired')
    expect(manifest.folder('movies/A')).to be_nil
    expect(manifest.folder('photos')).not_to be_nil
    expect(manifest.pending_deletions).to be_empty
    expect(manifest.history('movies/A').first).to have_attributes(event: 'removed', note: 'retired')
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

    it "records the folder's current drive and cause 'missing_on_nas'" do
      manifest.reconcile_pending('movies/Heat (1995)', [['a.srt', 'file']])
      expect(manifest.pending_deletions.first).to have_attributes(drive_serial: 'SN-backup-04-8tb', cause: 'missing_on_nas')
      expect(manifest.pending_deletions.first).not_to be_reassigned
    end

    it 'leaves a reassigned-cause row alone, even one sharing the folder_path' do
      manifest.reassign_folder('movies/Heat (1995)', 'SN-backup-07-8tb')   # schedules a 'reassigned' row for backup-04-8tb
      manifest.reconcile_pending('movies/Heat (1995)', [['a.srt', 'file']])   # missing_on_nas probe against its new drive

      by_cause = manifest.pending_deletions(folder_path: 'movies/Heat (1995)').group_by(&:cause)
      expect(by_cause['reassigned'].size).to eq(1)
      expect(by_cause['missing_on_nas'].size).to eq(1)

      manifest.reconcile_pending('movies/Heat (1995)', [])   # a.srt reappeared
      expect(manifest.pending_deletions(folder_path: 'movies/Heat (1995)').map(&:cause)).to eq(['reassigned'])
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

end
