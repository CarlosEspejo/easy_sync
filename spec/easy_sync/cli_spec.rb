# frozen_string_literal: true

RSpec.describe EasySync::CLI do
  let(:config_path) { File.join(temp_dir, 'rc.yml') }
  let(:mount_root) { File.join(temp_dir, 'Volumes') }
  let(:manifest_path) { File.join(temp_dir, 'manifest.sqlite3') }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  before do
    FileUtils.mkdir_p(mount_root)
    # `status` asks diskutil whether each unmounted drive is merely locked; by
    # default answer "nothing listed" so only the lock-specific test cares.
    fake_shell.on(->(argv) { argv == ['diskutil', 'apfs', 'list'] }, output: '')
    File.write(config_path, { mount_root: mount_root, manifest_path: manifest_path,
                              sources: [File.join(temp_dir, 'nas')],
                              dashboard_path: File.join(temp_dir, 'dashboard.html'),
                              log_dir: File.join(temp_dir, 'logs') }.to_yaml)
  end

  let(:keep_awake) { instance_double(EasySync::Jbod::KeepAwake, start: false) }

  def cli(*args)
    described_class.new(args, out: out, err: err, config_path: config_path, shell: fake_shell, keep_awake: keep_awake)
  end

  def manifest = EasySync::Jbod::Manifest.open(manifest_path)

  describe 'jbod register-drive' do
    let(:vol) { make_dirs(mount_root, 'backup-04-8tb').first }

    before do
      fake_shell.on('df', output: df_output(vol, capacity_kb: 8_000_000, used_kb: 1_000))
      fake_shell.on('diskutil', output: "   Volume UUID:               ABCD-1234\n")
    end

    it 'registers the drive using the Volume UUID and writes a marker' do
      expect(cli('register-drive', vol).run).to eq(0)
      drive = manifest.drives.first
      expect(drive).to have_attributes(serial_number: 'ABCD-1234', friendly_name: 'backup-04-8tb',
                                       capacity_bytes: 8_000_000 * 1024, volume_uuid: 'ABCD-1234',
                                       last_used_bytes: 1_000 * 1024)
      expect(JSON.parse(File.read(File.join(vol, EasySync::Jbod::MARKER_FILE)))['serial_number']).to eq('ABCD-1234')
      expect(out.string).to include('Registered backup-04-8tb (ABCD-1234)', 'SMART: unknown')
      expect(drive.smart_status).to eq('unknown')
    end

    it 'records SMART health at registration when the enclosure exposes it' do
      fake_shell.on(->(argv) { argv == ['diskutil', 'info', vol] }, output: "Part of Whole: disk3\nVolume UUID: ABCD-1234\n")
      fake_shell.on(->(argv) { argv == ['diskutil', 'info', 'disk3'] }, output: "APFS Physical Store: disk0s2\n")
      fake_shell.on(->(argv) { argv[0] == 'smartctl' }, output: <<~OUT)
        Serial Number:    WD-WX12345
        SMART overall-health self-assessment test result: PASSED
        ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
          5 Reallocated_Sector_Ct   0x0033   100   100   010    Pre-fail  Always       -       0
        194 Temperature_Celsius     0x0022   036   049   000    Old_age   Always       -       36
      OUT
      cli('register-drive', vol).run
      expect(manifest.drives.first).to have_attributes(serial_number: 'WD-WX12345', smart_status: 'ok',
                                                       smart_detail: 'PASSED · reallocated 0 · 36°C')
      expect(out.string).to include('SMART: ok (PASSED · reallocated 0 · 36°C)')
    end

    it 'prefers an explicit --serial and --name' do
      cli('register-drive', vol, '--serial', 'WD-WX12345', '--name', 'drive-four').run
      expect(manifest.drives.first).to have_attributes(serial_number: 'WD-WX12345', friendly_name: 'drive-four',
                                                       volume_uuid: 'ABCD-1234')
    end

    it 'refuses a volume that already carries a marker' do
      cli('register-drive', vol).run
      expect(cli('register-drive', vol, '--serial', 'other').run).to eq(1)
      expect(err.string).to include('already carries a marker')
      expect(manifest.drives.size).to eq(1)
    end

    it 'fails cleanly when the mount point does not exist' do
      expect(cli('register-drive', File.join(mount_root, 'nope')).run).to eq(1)
      expect(err.string).to include('not mounted')
    end

    it 'prefers the smartctl hardware serial over the diskutil Volume UUID when both resolve' do
      # Real diskutil info carries both "Part of Whole" and "Volume UUID" in the
      # same output - this fixture exercises both call sites against it.
      fake_shell.on(->(argv) { argv == ['diskutil', 'info', vol] }, output: <<~OUT)
           Part of Whole:             disk3
           Volume UUID:               ABCD-1234
      OUT
      fake_shell.on(->(argv) { argv == ['diskutil', 'info', 'disk3'] }, output: "APFS Physical Store: disk0s2\n")
      fake_shell.on(->(argv) { argv[0] == 'smartctl' }, output: "Serial Number: 0ba0284a20e0ec22\n")

      expect(cli('register-drive', vol).run).to eq(0)
      expect(manifest.drives.first).to have_attributes(serial_number: '0ba0284a20e0ec22', volume_uuid: 'ABCD-1234')
      expect(out.string).to include('Using the smartctl hardware serial')
    end
  end

  describe 'jbod reassign / history / status' do
    before do
      m = manifest
      m.register_drive(serial_number: 'S1', friendly_name: 'backup-01-3tb', capacity_bytes: 3 * TB)
      m.register_drive(serial_number: 'S2', friendly_name: 'backup-02-6tb', capacity_bytes: 6 * TB)
      m.assign_folder('Photos', 'S1')
      m.close
    end

    it 'records a manual move without touching data' do
      expect(cli('reassign', 'Photos', 'backup-02-6tb', '--note', 'copied by hand').run).to eq(0)
      expect(manifest.folder('Photos').drive_serial).to eq('S2')
      expect(out.string).to include('No data was moved')
      cli('history', 'Photos').run
      expect(out.string).to include('reassigned', 'copied by hand', 'assigned')
    end

    it 'rejects an unknown drive name' do
      expect(cli('reassign', 'Photos', 'backup-99').run).to eq(1)
      expect(err.string).to include('no drive named backup-99')
    end

    it 'prints status, including SMART health' do
      m = manifest
      m.update_drive_health('S2', status: 'warning', detail: 'PASSED · pending 3')
      m.close
      expect(cli('status').run).to eq(0)
      expect(out.string).to include('backup-01-3tb', 'not mounted', 'Photos', 'SMART unchecked', 'SMART warning: PASSED · pending 3')
    end
  end

  describe 'replace-drive' do
    let(:old_vol) { make_dirs(mount_root, 'backup-04-8tb').first }
    let(:new_vol) { make_dirs(mount_root, 'backup-08-12tb').first }

    before do
      m = manifest
      m.register_drive(serial_number: 'OLD', friendly_name: 'backup-04-8tb', capacity_bytes: 8 * TB)
      m.register_drive(serial_number: 'NEW', friendly_name: 'backup-08-12tb', capacity_bytes: 12 * TB)
      m.register_drive(serial_number: 'GONE', friendly_name: 'backup-00', capacity_bytes: 1 * TB)
      m.retire_drive('GONE')
      m.assign_folder('movies/A', 'OLD')
      m.assign_folder('movies/B', 'OLD')
      m.assign_folder('photos', 'NEW')
      m.close
    end

    it 'with --to: moves every folder to the new drive and retires the old one' do
      expect(cli('replace-drive', 'backup-04-8tb', '--to', 'backup-08-12tb').run).to eq(0)
      m = manifest
      expect(m.folders_on('NEW').map(&:folder_path)).to eq(['movies/A', 'movies/B', 'photos'])
      expect(m.drive('OLD')).to be_retired
      expect(m.drives.map(&:friendly_name)).to eq(['backup-08-12tb'])
      expect(out.string).to include('Retired backup-04-8tb', '2 folders now recorded on backup-08-12tb', 'copy them there from the NAS')
      expect(fake_shell.calls_to('rsync')).to be_empty
    end

    it 'without --to: forgets the folders so the next sync places them afresh' do
      expect(cli('replace-drive', 'backup-04-8tb').run).to eq(0)
      m = manifest
      expect(m.folder('movies/A')).to be_nil
      expect(m.folder('photos').drive_serial).to eq('NEW')
      expect(m.drive('OLD')).to be_retired
      expect(out.string).to include('2 folders forgotten', 'place them afresh')
    end

    it 'with --copy: rsyncs old to new over the local bus first, then records the move' do
      %w[OLD NEW].zip([old_vol, new_vol]).each do |serial, vol|
        write_file(File.join(vol, EasySync::Jbod::MARKER_FILE), %({"serial_number":"#{serial}","friendly_name":"x"}))
      end
      fake_shell.on(->(argv) { argv[0] == 'df' && argv.last == old_vol }, output: df_output(old_vol, capacity_kb: 8_000_000, used_kb: 5_000_000))
      fake_shell.on(->(argv) { argv[0] == 'df' && argv.last == new_vol }, output: df_output(new_vol, capacity_kb: 12_000_000, used_kb: 10))
      fake_shell.on('rsync', output: rsync_stats)

      expect(cli('replace-drive', 'backup-04-8tb', '--to', 'backup-08-12tb', '--copy').run).to eq(0)
      copy = fake_shell.calls_to('rsync').first
      expect(copy[0..1]).to eq(['rsync', '-a'])
      expect(copy).to include('--exclude=.easy_sync', '--exclude=#recycle')
      expect(copy.last(2)).to eq(["#{old_vol}/", "#{new_vol}/"])
      expect(manifest.folders_on('NEW').size).to eq(3)
      expect(out.string).to include('Copying backup-04-8tb -> backup-08-12tb', 'verify them against the NAS')
    end

    it 'with --copy: refuses when the new drive is too small, or the copy fails, leaving the manifest untouched' do
      %w[OLD NEW].zip([old_vol, new_vol]).each do |serial, vol|
        write_file(File.join(vol, EasySync::Jbod::MARKER_FILE), %({"serial_number":"#{serial}","friendly_name":"x"}))
      end
      fake_shell.on(->(argv) { argv[0] == 'df' && argv.last == old_vol }, output: df_output(old_vol, capacity_kb: 8_000_000, used_kb: 5_000_000))
      fake_shell.on(->(argv) { argv[0] == 'df' && argv.last == new_vol }, output: df_output(new_vol, capacity_kb: 12_000_000, used_kb: 11_000_000))
      expect(cli('replace-drive', 'backup-04-8tb', '--to', 'backup-08-12tb', '--copy').run).to eq(1)
      expect(err.string).to include('has 976.6 MB free but backup-04-8tb holds 4.8 GB')
      expect(manifest.drive('OLD')).not_to be_retired

      fake_shell.on(->(argv) { argv[0] == 'df' && argv.last == new_vol }, output: df_output(new_vol, capacity_kb: 12_000_000, used_kb: 10))
      fake_shell.on('rsync', output: 'boom', status: 23)
      expect(cli('replace-drive', 'backup-04-8tb', '--to', 'backup-08-12tb', '--copy').run).to eq(1)
      expect(err.string).to include('copy failed (rsync exit 23); nothing was changed')
      expect(manifest.folders_on('OLD').size).to eq(2)
    end

    it 'rejects unknown, retired, identical and unmounted drives clearly' do
      expect(cli('replace-drive', 'nope').run).to eq(1)
      expect(err.string).to include('no drive named nope')
      expect(cli('replace-drive', 'backup-00').run).to eq(1)
      expect(err.string).to include('already retired')
      expect(cli('replace-drive', 'backup-04-8tb', '--to', 'backup-04-8tb').run).to eq(1)
      expect(err.string).to include('same')
      expect(cli('replace-drive', 'backup-04-8tb', '--copy').run).to eq(1)
      expect(err.string).to include('--copy needs --to')
      expect(cli('replace-drive', 'backup-04-8tb', '--to', 'backup-08-12tb', '--copy').run).to eq(1)
      expect(err.string).to include('backup-04-8tb is not mounted (needed for --copy)')
    end

    it 'lists retired drives in status, and names them in history' do
      cli('replace-drive', 'backup-04-8tb', '--to', 'backup-08-12tb').run
      out.truncate(0)
      cli('status').run
      expect(out.string).to include('backup-04-8tb', 'retired 20')
      out.truncate(0)
      cli('history', 'movies/A').run
      expect(out.string).to include('reassigned', '-> backup-08-12tb', 'backup-04-8tb replaced by backup-08-12tb')
    end
  end

  describe 'clean' do
    it 'removes excluded junk from mounted drives and reports what it freed' do
      vol = make_dirs(mount_root, 'backup-01-3tb').first
      write_file(File.join(vol, EasySync::Jbod::MARKER_FILE), '{"serial_number":"S1","friendly_name":"backup-01-3tb"}')
      fake_shell.on('df', output: df_output(vol, capacity_kb: 3_000_000, used_kb: 1_000))
      m = manifest
      m.register_drive(serial_number: 'S1', friendly_name: 'backup-01-3tb', capacity_bytes: 3 * TB)
      m.assign_folder('pro', 'S1')
      m.close
      write_file(File.join(vol, 'pro', '#recycle', 'junk.bin'), 'x' * 2048)
      write_file(File.join(vol, 'pro', 'keep.mp4'))

      expect(cli('clean', '--dry-run').run).to eq(0)
      expect(File).to exist(File.join(vol, 'pro', '#recycle', 'junk.bin'))
      expect(cli('clean').run).to eq(0)
      expect(File).not_to exist(File.join(vol, 'pro', '#recycle'))
      expect(File).to exist(File.join(vol, 'pro', 'keep.mp4'))
      expect(out.string).to include('would remove pro/#recycle', 'Removed 1 entry, 2.0 KB freed')
    end

    it 'refuses when no registered drive is mounted' do
      expect(cli('clean').run).to eq(1)
      expect(err.string).to include('no registered drive is mounted')
    end

    it 'lets a dry run look while a sync holds the lock, but not a real clean' do
      cfg = YAML.safe_load_file(config_path, permitted_classes: [Symbol], symbolize_names: true)
      lock_path = File.join(temp_dir, 'jbod.lock')
      File.write(config_path, cfg.merge(lock_path: lock_path).to_yaml)
      File.write(lock_path, Process.pid.to_s)
      expect(cli('clean', '--dry-run').run).to eq(1)        # fails later, on "no drive mounted", not on the lock
      expect(err.string).to include('no registered drive is mounted')
      expect(cli('clean').run).to eq(1)
      expect(err.string).to include('already running')
    end
  end

  describe 'add-source / remove-source / sources' do
    let(:tv) { make_dirs(File.join(temp_dir, 'shares'), 'tv').first }

    before { make_dirs(tv, 'Show A', 'Show B') }

    it 'adds a share with an explicit setting and lists it' do
      expect(cli('add-source', tv, '--whole').run).to eq(0)
      expect(out.string).to include("Added #{tv} (split: false, as you asked)")
      expect(EasySync::Config.load(config_path).first.source_entries.last).to eq({ path: tv, split: false })
      out.truncate(0); out.rewind
      cli('sources').run
      expect(out.string).to include("#{tv}", 'whole', 'mounted')
    end

    it 'infers split when no drive is registered yet, and whole for a share with loose files' do
      cli('add-source', tv).run
      expect(out.string).to include('split: true, no drive registered yet', 'Run `easy_sync plan`')
      loose = make_dirs(File.join(temp_dir, 'shares'), 'synology').first
      write_file(File.join(loose, 'Boxing.mp4'))
      out.truncate(0); out.rewind
      cli('add-source', loose).run
      expect(out.string).to include('split: false, 1 loose file')
    end

    it 'uses the planner rule once a drive is registered' do
      m = manifest
      m.register_drive(serial_number: 'S1', friendly_name: 'backup-01-3tb', capacity_bytes: 3 * TB)
      m.close
      fake_shell.on('du', output: ->(argv) { argv[2..].map { |p| "#{5 * 1024 * 1024}\t#{p}\n" }.join })   # 5 GB each
      cli('add-source', tv).run
      expect(out.string).to include('split: false', 'fits comfortably')
    end

    it 'refuses an unmounted or duplicate share, and removes one without touching drives' do
      expect(cli('add-source', File.join(temp_dir, 'nope')).run).to eq(1)
      expect(err.string).to include('not mounted')
      cli('add-source', tv, '--split').run
      expect(cli('add-source', tv, '--split').run).to eq(1)
      expect(err.string).to include('already a source')
      expect(cli('remove-source', tv).run).to eq(0)
      expect(out.string).to include("Removed #{tv}. Nothing on the drives was touched")
      expect(EasySync::Config.load(config_path).first.source_entries.map { |e| e[:path] }).not_to include(tv)
    end
  end

  describe 'jbod sync' do
    def merge_jbod_config(**overrides)
      cfg = YAML.safe_load_file(config_path, permitted_classes: [Symbol], symbolize_names: true)
      File.write(config_path, cfg.merge(overrides).to_yaml)
    end

    it 'refuses to run with an old rsync' do
      fake_shell.on('rsync', output: "rsync  version 2.6.9  protocol version 29\n")
      expect(cli('sync').run).to eq(1)
      expect(err.string).to include('too old')
    end

    it 'refuses a second concurrent run and leaves an already-running lock untouched' do
      lock_path = File.join(temp_dir, 'jbod.lock')
      merge_jbod_config(lock_path: lock_path)
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.write(lock_path, Process.pid.to_s) # simulate a live concurrent run
      fake_shell.on('rsync', output: "rsync  version 3.5.0  protocol version 32\n")

      expect(cli('sync').run).to eq(1)
      expect(err.string).to include('already running', "pid #{Process.pid}")
      expect(File.read(lock_path)).to eq(Process.pid.to_s)
    end

    it 'keeps the Mac awake for the run unless told not to' do
      merge_jbod_config(sources: [])
      fake_shell.on('rsync', output: "rsync  version 3.5.0  protocol version 32\n")
      allow(keep_awake).to receive(:start).and_return(true)

      cli('sync').run
      expect(keep_awake).to have_received(:start).once
      expect(out.string).to include('Keeping the Mac awake for this run (caffeinate).')

      cli('sync', '--no-keep-awake').run
      expect(keep_awake).to have_received(:start).once   # not called again
    end

    it 'respects keep_awake: false in the config' do
      merge_jbod_config(sources: [], keep_awake: false)
      fake_shell.on('rsync', output: "rsync  version 3.5.0  protocol version 32\n")
      cli('sync').run
      expect(keep_awake).not_to have_received(:start)
    end

    it 'releases the lock after a run so a later sync can proceed' do
      lock_path = File.join(temp_dir, 'jbod.lock')
      merge_jbod_config(lock_path: lock_path, sources: [])
      fake_shell.on('rsync', output: "rsync  version 3.5.0  protocol version 32\n")

      cli('sync').run # fails fast (no sources configured), but the lock must still be released
      expect(File).not_to exist(lock_path)
    end
  end

  describe 'jbod pending' do
    it 'lists candidates with their expiry' do
      m = manifest
      m.register_drive(serial_number: 'S1', friendly_name: 'backup-01-3tb', capacity_bytes: 3 * TB)
      m.assign_folder('photos', 'S1')
      m.reconcile_pending('photos', [['old.jpg', 'file'], ['', 'folder']], at: '2026-09-01T00:00:00Z')
      m.close
      expect(cli('pending').run).to eq(0)
      expect(out.string).to include('2 pending', 'photos/old.jpg', 'photos (whole folder)', 'since 2026-09-01')
    end

    it 'says so when nothing is pending' do
      cli('pending').run
      expect(out.string).to include('Nothing is pending deletion')
    end
  end

  describe '--config' do
    let(:other_config) { File.join(temp_dir, 'other.yml') }

    before do
      File.write(other_config, { manifest_path: File.join(temp_dir, 'other.sqlite3'),
                                 mount_root: mount_root, sources: [] }.to_yaml)
      m = manifest
      m.register_drive(serial_number: 'S1', friendly_name: 'backup-01-3tb', capacity_bytes: 3 * TB)
      m.close
    end

    it 'reads the config named by --config PATH, placed before the command' do
      code = described_class.new(['--config', other_config, 'status'], out: out, err: err, shell: fake_shell).run
      expect(code).to eq(0)
      expect(out.string).not_to include('backup-01-3tb')   # the other manifest has no drives
    end

    it 'accepts --config=PATH' do
      described_class.new(["--config=#{config_path}", 'status'], out: out, err: err, shell: fake_shell).run
      expect(out.string).to include('backup-01-3tb')
    end

    it 'falls back to EASY_SYNC_CONFIG, then to the default path' do
      described_class.new(%w[status], out: out, err: err, shell: fake_shell,
                                           env: { 'EASY_SYNC_CONFIG' => config_path }).run
      expect(out.string).to include('backup-01-3tb')
      expect(described_class.new([], env: {}).instance_variable_get(:@config_path)).to eq(EasySync::Config.default_path)
    end

    it 'lets --config override EASY_SYNC_CONFIG' do
      described_class.new(['--config', other_config, 'status'], out: out, err: err, shell: fake_shell,
                                                                        env: { 'EASY_SYNC_CONFIG' => config_path }).run
      expect(out.string).not_to include('backup-01-3tb')
    end

    it 'fails cleanly when --config has no path' do
      expect(described_class.new(['--config'], out: out, err: err, shell: fake_shell).run).to eq(1)
      expect(err.string).to include('--config needs a path')
    end
  end

  describe 'jbod status with a locked drive' do
    it 'says the drive is locked instead of merely not mounted' do
      m = manifest
      m.register_drive(serial_number: 'S1', friendly_name: 'jbod-test-2', capacity_bytes: 3 * TB)
      m.close
      fake_shell.on(->(argv) { argv == ['diskutil', 'apfs', 'list'] }, output: <<~OUT)
            Name:                      jbod-test-2 (Case-insensitive)
            Mount Point:               Not Mounted
            FileVault:                 Yes (Locked)
      OUT
      cli('status').run
      expect(out.string).to include('connected but LOCKED', 'diskutil apfs unlockVolume jbod-test-2')
    end
  end

  describe 'jbod plan' do
    it 'prints measurements and a recommendation per share, and --apply writes it to the config' do
      nas = make_dirs(temp_dir, 'nas').first
      make_dirs(nas, 'A', 'B')
      fake_shell.on('du', output: ->(argv) { argv[2..].map { |p| "#{9 * 1024 * 1024 * 1024}\t#{p}\n" }.join })
      expect(cli('plan', '--largest-drive', '8tb').run).to eq(0)
      expect(out.string).to include('Judging against the largest drive: 8.0 TB', '18.0 TB in 2 folders, largest A (9.0 TB)',
                                    'recommend split: true', 'bigger than the largest drive currently registered',
                                    'will fit once you add a bigger drive', 'CHANGE the config',
                                    'Run `easy_sync plan --apply`')
      expect(EasySync::Config.load(config_path).first.source_entries).to eq([{ path: nas, split: false }])

      expect(cli('plan', '--largest-drive', '8tb', '--apply').run).to eq(0)
      expect(out.string).to include('Updated 1 source in')
      expect(EasySync::Config.load(config_path).first.source_entries).to eq([{ path: nas, split: true }])
      expect(File.read(config_path)).to include('# easy_sync configuration')
    end

    it 'rejects a size it cannot parse' do
      expect(cli('plan', '--largest-drive', 'huge').run).to eq(1)
      expect(err.string).to include('cannot parse size')
    end

    it 'judges only the named share(s) when given, leaving the rest unmeasured' do
      pro = make_dirs(temp_dir, 'pro').first
      movies = make_dirs(temp_dir, 'movies').first
      make_dirs(pro, 'Course 1')
      make_dirs(movies, 'Film 1')
      cfg = YAML.safe_load_file(config_path, permitted_classes: [Symbol], symbolize_names: true)
      File.write(config_path, cfg.merge(sources: [{ path: pro, split: false }, { path: movies, split: true }]).to_yaml)
      fake_shell.on('du', output: ->(argv) { argv[2..].map { |p| "1024\t#{p}\n" }.join })

      expect(cli('plan', 'pro', '--largest-drive', '8tb').run).to eq(0)
      expect(out.string).to include(pro)
      expect(out.string).not_to include(movies)

      out.truncate(0)
      out.rewind
      expect(cli('plan', movies, '--largest-drive', '8tb').run).to eq(0)
      expect(out.string).to include(movies)
      expect(out.string).not_to include(pro)
    end

    it 'fails clearly when no configured source matches the given name' do
      expect(cli('plan', 'nonexistent-share', '--largest-drive', '8tb').run).to eq(1)
      expect(err.string).to include('no configured source matches nonexistent-share')
    end
  end

  it 'writes a run log for every sync and echoes the same lines to the terminal' do
    fake_shell.on('rsync', output: "rsync  version 3.5.0  protocol version 32\n")
    cli('sync').run   # fails fast: the configured source is not mounted
    logs = Dir.glob(File.join(temp_dir, 'logs', 'sync-*.log'))
    expect(logs.size).to eq(1)
    expect(File.read(logs.first)).to include('easy_sync 2.0.0', 'rsync 3.5.0')
    expect(out.string).to include('easy_sync 2.0.0')
  end

  it 'turns Ctrl-C into a calm message and exit 130, releasing the lock' do
    lock_path = File.join(temp_dir, 'jbod.lock')
    cfg = YAML.safe_load_file(config_path, permitted_classes: [Symbol], symbolize_names: true)
    File.write(config_path, cfg.merge(lock_path: lock_path, sources: [File.join(temp_dir, 'nas')]).to_yaml)
    make_dirs(temp_dir, 'nas', 'nas/photos')
    write_file(File.join(temp_dir, 'nas', 'photos', 'x.jpg'))
    fake_shell.on('rsync', output: "rsync  version 3.5.0  protocol version 32\n")
    fake_shell.on('du', output: ->(_) { raise Interrupt })   # the user hits Ctrl-C while a folder is measured

    expect(cli('sync').run).to eq(130)
    expect(err.string).to include('Interrupted. Nothing is lost')
    expect(File).not_to exist(lock_path)
    expect(Dir.glob(File.join(temp_dir, 'logs', 'sync-*.log')).size).to eq(1)
  end

  it 'prints the version' do
    %w[--version -v version].each do |arg|
      out.rewind
      out.truncate(0)
      expect(cli(arg).run).to eq(0)
      expect(out.string).to eq("easy_sync #{EasySync::VERSION}\n")
    end
  end

  it 'prints usage for unknown commands' do
    expect(cli('bogus').run).to eq(1)
    expect(err.string).to include('Unknown command: bogus', 'Usage:')
  end

  it 'prints grouped, aligned usage, and a get-started hint while nothing is configured' do
    File.delete(config_path)   # a brand-new user: no config at all yet
    expect(cli.run).to eq(0)
    expect(File).to exist(config_path)   # bare `easy_sync` is enough to create it
    expect(err.string).to include('Generated sample config file')
    expect(out.string).to include('Usage: easy_sync', 'Set up, once:', 'Back up:', 'Maintain:', 'Global options:', '--version')
    table = out.string.split('Nothing is configured').first
    rows = table.lines.select { |l| l.start_with?('  ') && l.index('  ', 2) }
    expect(rows.size).to be > 12
    expect(rows.map { |l| l.index(/\S/, l.index('  ', 2)) }.uniq.size).to eq(1)   # every description starts in the same column
    expect(out.string).to include('Nothing is configured yet', 'easy_sync add-source /Volumes/<share>')
    expect(fake_shell.calls).to be_empty

    EasySync::Config.load(config_path).first.tap { |c| c.add_source('/Volumes/x', split: true); c.save }
    out.truncate(0); out.rewind
    cli.run
    expect(out.string).not_to include('Nothing is configured yet')
  end
end
