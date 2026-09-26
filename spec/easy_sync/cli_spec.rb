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

  def cli(*args, clock: Time)
    described_class.new(args, out: out, err: err, config_path: config_path, shell: fake_shell, keep_awake: keep_awake, clock: clock)
  end

  def manifest = EasySync::Jbod::Manifest.open(manifest_path)

  describe 'register-drive' do
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

    it 'records SMART health and the drive model at registration when the enclosure exposes it' do
      fake_shell.on(->(argv) { argv == ['diskutil', 'info', vol] }, output: "Part of Whole: disk3\nVolume UUID: ABCD-1234\n")
      fake_shell.on(->(argv) { argv == ['diskutil', 'info', 'disk3'] }, output: "APFS Physical Store: disk0s2\n")
      fake_shell.on(->(argv) { argv[0] == 'smartctl' }, output: <<~OUT)
        Serial Number:    WD-WX12345
        Device Model:     WDC WD80EFZZ-68BTXN0
        SMART overall-health self-assessment test result: PASSED
        ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
          5 Reallocated_Sector_Ct   0x0033   100   100   010    Pre-fail  Always       -       0
        194 Temperature_Celsius     0x0022   036   049   000    Old_age   Always       -       36
      OUT
      cli('register-drive', vol).run
      expect(manifest.drives.first).to have_attributes(serial_number: 'WD-WX12345', smart_status: 'ok',
                                                       smart_detail: 'PASSED · reallocated 0 · 36°C',
                                                       model: 'WDC WD80EFZZ-68BTXN0')
      expect(out.string).to include('SMART: ok (PASSED · reallocated 0 · 36°C)', 'Western Digital WD80EFZZ-68BTXN0')
    end

    it 'leaves the model nil when smartctl exposes no model line' do
      fake_shell.on(->(argv) { argv == ['diskutil', 'info', vol] }, output: "Part of Whole: disk3\nVolume UUID: ABCD-1234\n")
      fake_shell.on(->(argv) { argv == ['diskutil', 'info', 'disk3'] }, output: "APFS Physical Store: disk0s2\n")
      fake_shell.on(->(argv) { argv[0] == 'smartctl' }, output: "Serial Number:    WD-WX12345\n")
      cli('register-drive', vol).run
      expect(manifest.drives.first.model).to be_nil
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

  describe 'reassign / history / status' do
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

    it 'schedules the old drive copy for grace-period cleanup' do
      cli('reassign', 'Photos', 'backup-02-6tb').run
      pending = manifest.pending_deletions(folder_path: 'Photos').first
      expect(pending).to have_attributes(cause: 'reassigned', drive_serial: 'S1')
    end

    context 'with --copy (drive-to-drive instead of from the NAS)' do
      def mount_drive(name, serial)
        vol = make_dirs(mount_root, name).first
        write_file(File.join(vol, EasySync::Jbod::MARKER_FILE), { serial_number: serial, friendly_name: name }.to_json)
        vol
      end

      let!(:old_vol) { mount_drive('backup-01-3tb', 'S1') }
      let!(:new_vol) { mount_drive('backup-02-6tb', 'S2') }

      before do
        fake_shell.on('df', output: ->(argv) { df_output(argv.last, capacity_kb: 3 * 1024**3, used_kb: 1024) })
        write_file(File.join(old_vol, 'Photos', '2024', 'a.jpg'))
      end

      it 'copies the folder between the drives, then records the move and schedules the old copy for cleanup' do
        fake_shell.on('rsync', output: rsync_stats)
        expect(cli('reassign', 'Photos', 'backup-02-6tb', '--copy').run).to eq(0)
        call = fake_shell.calls_to('rsync').last
        expect(call.last(2)).to eq(["#{old_vol}/Photos/", "#{new_vol}/Photos/"])
        expect(call).not_to include('--delete', '--exclude=/*/')
        expect(manifest.folder('Photos')).to have_attributes(drive_serial: 'S2', last_synced_at: nil)
        expect(manifest.pending_deletions(folder_path: 'Photos').first).to have_attributes(cause: 'reassigned', drive_serial: 'S1')
        expect(out.string).to include('Copying Photos: backup-01-3tb -> backup-02-6tb', 'The next sync confirms the copy')
      end

      it 'moves every folder of a share when given the share name, copying only loose files for its root unit' do
        m = manifest
        m.assign_folder('tv', 'S1', scope: 'root')
        m.assign_folder('tv/Show A', 'S1')
        m.assign_folder('tv/Show B', 'S2')   # already there: left alone
        m.close
        write_file(File.join(old_vol, 'tv', 'notes.txt'))
        write_file(File.join(old_vol, 'tv', 'Show A', 'ep1.mkv'))
        fake_shell.on('rsync', output: rsync_stats)

        expect(cli('reassign', 'tv', 'backup-02-6tb', '--copy').run).to eq(0)
        calls = fake_shell.calls_to('rsync')
        expect(calls.map { |c| c.last }).to eq(["#{new_vol}/tv/", "#{new_vol}/tv/Show A/"])
        expect(calls.first).to include('--exclude=/*/')
        expect(calls.last).not_to include('--exclude=/*/')
        expect(manifest.folders.select { |f| f.share == 'tv' }.map(&:drive_serial).uniq).to eq(['S2'])
        expect(out.string).to include('2 folders of tv are now on backup-02-6tb')
      end

      it 'leaves the manifest as it was when the copy fails' do
        fake_shell.on('rsync', output: 'rsync error', status: 23)
        expect(cli('reassign', 'Photos', 'backup-02-6tb', '--copy').run).to eq(1)
        expect(err.string).to include('copying Photos failed (rsync exit 23); it is still recorded on backup-01-3tb')
        expect(manifest.folder('Photos').drive_serial).to eq('S1')
        expect(manifest.pending_deletions).to be_empty
      end

      it 'refuses when the folder\'s current drive is not mounted, changing nothing' do
        FileUtils.rm_rf(old_vol)
        expect(cli('reassign', 'Photos', 'backup-02-6tb', '--copy').run).to eq(1)
        expect(err.string).to include('backup-01-3tb not mounted; --copy needs both drives')
        expect(manifest.folder('Photos').drive_serial).to eq('S1')
        expect(fake_shell.calls_to('rsync')).to be_empty
      end
    end

    context 'capacity check' do
      before do
        m = manifest
        m.assign_folder('Movies', 'S1', size_bytes: 5 * TB)
        m.close
      end

      def mount_target(free_tb:, capacity_tb: 6)
        vol = make_dirs(mount_root, 'backup-02-6tb').first
        write_file(File.join(vol, EasySync::Jbod::MARKER_FILE), { serial_number: 'S2', friendly_name: 'backup-02-6tb' }.to_json)
        used_tb = capacity_tb - free_tb
        fake_shell.on(->(argv) { argv[0] == 'df' && argv.last == vol },
                      output: df_output(vol, capacity_kb: capacity_tb * 1024**3, used_kb: used_tb * 1024**3))
      end

      it 'refuses a drive that does not have room' do
        mount_target(free_tb: 4)   # Movies is 5 TB
        expect(cli('reassign', 'Movies', 'backup-02-6tb').run).to eq(1)
        expect(err.string).to include('Movies', 'does not fit on backup-02-6tb', 'Use --force')
        expect(manifest.folder('Movies').drive_serial).to eq('S1')
      end

      it '--force reassigns anyway' do
        mount_target(free_tb: 4)
        expect(cli('reassign', 'Movies', 'backup-02-6tb', '--force').run).to eq(0)
        expect(manifest.folder('Movies').drive_serial).to eq('S2')
      end

      it 'allows a drive that has room' do
        mount_target(free_tb: 6)
        expect(cli('reassign', 'Movies', 'backup-02-6tb').run).to eq(0)
        expect(manifest.folder('Movies').drive_serial).to eq('S2')
      end

      it "proceeds without checking when the target isn't mounted, but says so" do
        expect(cli('reassign', 'Movies', 'backup-02-6tb').run).to eq(0)
        expect(out.string).to include("backup-02-6tb is not mounted; couldn't check whether it has room")
        expect(manifest.folder('Movies').drive_serial).to eq('S2')
      end

      it 'ignores what is already promised to the target drive when checking, not just live free space' do
        # backup-02-6tb reads 6 TB free live (nothing copied there yet), but
        # 3 TB of it is already promised to another unsynced folder - so only
        # 3 TB is really available, not enough for a second 5 TB folder.
        manifest.assign_folder('Shows', 'S2', size_bytes: 3 * TB)
        mount_target(free_tb: 6)
        expect(cli('reassign', 'Movies', 'backup-02-6tb').run).to eq(1)
        expect(err.string).to include('does not fit on backup-02-6tb')
      end
    end

    it 'prints status, including SMART health, and a folder summary (no per-folder listing by default)' do
      m = manifest
      m.update_drive_health('S1', status: 'ok', detail: 'PASSED · reallocated 0 · pending 0 · uncorrectable 0 · 44°C')
      m.update_drive_health('S2', status: 'warning', detail: 'PASSED · reallocated 0 · pending 3 · 39°C')
      m.close
      expect(cli('status').run).to eq(0)
      expect(out.string).to include('DRIVE', 'backup-01-3tb', 'not mounted', 'ok · 44°C', 'warning · pending 3 · 39°C', '1 placed')
      expect(out.string).not_to include('Photos')
      expect(out.string).not_to include('reallocated 0', 'PASSED')   # zero counters and the implied verdict are noise
      rows = out.string.lines.grep(/backup-0[12]-/)
      expect(rows.map { |l| l.index(/ok ·|warning ·/) }.uniq.size).to eq(1)   # SMART column lines up
    end

    it 'says when an n/a SMART reading was taken, so a stale one is recognisable' do
      m = manifest
      m.update_drive_health('S1', status: 'unknown', detail: 'SMART not exposed by this enclosure',
                                  checked_at: '2026-09-24T03:25:29Z')
      m.close
      expect(cli('status').run).to eq(0)
      expect(out.string).to include("n/a (as of #{Time.parse('2026-09-24T03:25:29Z').localtime.strftime('%Y-%m-%d %H:%M')})")
    end

    it "shows whether Backblaze has uploaded each drive, and nothing about it when it isn't installed" do
      expect(cli('status').run).to eq(0)
      expect(out.string).not_to include('BACKBLAZE', 'Backblaze')

      fake_backblaze({ File.join(mount_root, 'backup-01-3tb') => { files: 0, bytes: 0, scanned_at: Time.now },
                       File.join(mount_root, 'backup-02-6tb') => { files: 12, bytes: 4 * 1000**3, scanned_at: Time.now } })
      out.truncate(0); out.rewind
      expect(cli('status').run).to eq(0)
      expect(out.string).to include('BACKBLAZE', 'up to date', 'uploading, 12 files (3.7 GB) left',
                                    'Backblaze: 1 of 2 drives not up to date yet; last backup pass finished')
    end

    describe '--smart' do
      let!(:vol) do
        make_dirs(mount_root, 'backup-02-6tb').first.tap do |v|
          write_file(File.join(v, EasySync::Jbod::MARKER_FILE), { serial_number: 'S2', friendly_name: 'backup-02-6tb' }.to_json)
          fake_shell.on(->(argv) { argv[0] == 'df' && argv.last == v }, output: df_output(v, capacity_kb: 6 * 1024**3, used_kb: 0))
        end
      end

      def smartctl_reports(reallocated:)
        fake_shell.on(->(argv) { argv == ['diskutil', 'info', vol] }, output: "Part of Whole: disk3\n")
        fake_shell.on(->(argv) { argv == ['diskutil', 'info', 'disk3'] }, output: "APFS Physical Store: disk0s2\n")
        fake_shell.on(->(argv) { argv[0] == 'smartctl' }, output: <<~OUT)
          SMART overall-health self-assessment test result: PASSED
          ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
            5 Reallocated_Sector_Ct   0x0033   100   100   010    Pre-fail  Always       -       #{reallocated}
          194 Temperature_Celsius     0x0022   036   049   000    Old_age   Always       -       37
        OUT
      end

      before do
        m = manifest
        m.update_drive_health('S1', status: 'ok', detail: 'PASSED · 44°C')
        m.update_drive_health('S2', status: 'unknown', detail: 'SMART not exposed by this enclosure')
        m.close
      end

      it 'reads SMART from the mounted drives now, without saving it' do
        smartctl_reports(reallocated: 0)
        expect(cli('status', '--smart').run).to eq(0)
        expect(out.string.lines.grep(/backup-02-6tb/).first).to include('ok · 37°C')
        expect(out.string.lines.grep(/backup-01-3tb/).first).to include('ok · 44°C')   # unmounted: last reading
        expect(out.string).to include('SMART read just now from the mounted drives (not saved)')
        expect(manifest.drive('S2')).to have_attributes(smart_status: 'unknown')
      end

      it 'shows reallocated sectors at the verified baseline as stable wear, as a sync would' do
        smartctl_reports(reallocated: 24)
        m = manifest
        m.record_smart_check('S2', reallocated_sector_ct: 24)
        m.verify_drive_stable('S2')
        m.close
        expect(cli('status', '--smart').run).to eq(0)
        expect(out.string.lines.grep(/backup-02-6tb/).first).to include('stable wear · reallocated 24')
      end

      it 'is not run without the flag' do
        smartctl_reports(reallocated: 0)
        expect(cli('status').run).to eq(0)
        expect(fake_shell.calls_to('smartctl')).to be_empty
        expect(out.string.lines.grep(/backup-02-6tb/).first).to include('n/a')
      end
    end

    it 'sums capacity and free space across all drives, live numbers where mounted, last-known otherwise' do
      m = manifest
      m.update_drive_usage('S1', used_bytes: 1 * TB, free_bytes: 2 * TB)   # S1 stays unmounted: falls back to this
      m.close
      vol = make_dirs(mount_root, 'backup-02-6tb').first
      write_file(File.join(vol, EasySync::Jbod::MARKER_FILE), { serial_number: 'S2', friendly_name: 'backup-02-6tb' }.to_json)
      fake_shell.on(->(argv) { argv[0] == 'df' && argv.last == vol },
                    output: df_output(vol, capacity_kb: 4 * 1024**3, used_kb: 0))   # 4 TB free, live

      expect(cli('status').run).to eq(0)
      # capacity: registered 3 TB (S1) + 6 TB (S2) = 9 TB, regardless of mount state
      # free: S1's last-known 2 TB + S2's live 4 TB = 6 TB
      expect(out.string).to include('Total: 9.0 TB capacity, 6.0 TB free right now')
    end

    it 'omits the total line when no drives are registered' do
      m = manifest
      m.retire_drive('S1')
      m.retire_drive('S2')
      m.close
      expect(cli('status').run).to eq(0)
      expect(out.string).not_to include('Total:')
    end

    it 'shows the drive manufacturer and model next to the serial when known, and nothing extra when not' do
      manifest.register_drive(serial_number: 'S3', friendly_name: 'backup-03-8tb', capacity_bytes: 8 * TB,
                              model: 'WDC WD80EFZZ-68BTXN0')
      manifest.close
      expect(cli('status').run).to eq(0)
      expect(out.string).to include('S3 · Western Digital WD80EFZZ-68BTXN0')
      expect(out.string).to match(/\bS1(?! ·)/)
    end

    it '--all lists every placed folder, for piping' do
      expect(cli('status', '--all').run).to eq(0)
      expect(out.string).to include('Photos')
    end

    it '--all aligns the drive column even when a folder name is longer than the old fixed width' do
      m = manifest
      long_name = 'A' * 40
      m.assign_folder(long_name, 'S2')
      m.close
      expect(cli('status', '--all').run).to eq(0)
      folder_lines = out.string.split("Folders:\n").last.lines
      drive_columns = folder_lines.grep(/backup-0[12]/).map { |l| l =~ /backup-0[12]/ }
      expect(drive_columns.uniq.size).to eq(1)
    end

    it 'counts failed folders in the summary, singular and plural' do
      m = manifest
      m.record_sync(folder_path: 'Photos', drive_serial: 'S1', started_at: 't0', finished_at: 't1', exit_status: 23)
      m.close
      expect(cli('status').run).to eq(0)
      expect(out.string).to include('1 folder failed their last sync')

      m = manifest
      m.assign_folder('Videos', 'S2')
      m.record_sync(folder_path: 'Videos', drive_serial: 'S2', started_at: 't0', finished_at: 't1', exit_status: 23)
      m.close
      out.truncate(0)
      expect(cli('status').run).to eq(0)
      expect(out.string).to include('2 folders failed their last sync')
    end

    it 'caps the retired list to the most recent, newest first, with the rest behind --all' do
      m = manifest
      6.times do |i|
        m.register_drive(serial_number: "OLD#{i}", friendly_name: "old-#{i}", capacity_bytes: 1 * TB)
        m.retire_drive("OLD#{i}", at: "2026-01-0#{i + 1}T12:00:00Z")   # noon UTC so it doesn't roll back a day in local time
      end
      m.close

      expect(cli('status').run).to eq(0)
      expect(out.string).to include('Retired: old-5 (2026-01-06), old-4 (2026-01-05), old-3 (2026-01-04), ' \
                                    'old-2 (2026-01-03), old-1 (2026-01-02) · 1 more (see `status --all`)')
      expect(out.string).not_to include('old-0')

      out.truncate(0)
      expect(cli('status', '--all').run).to eq(0)
      expect(out.string).to include('old-0 (2026-01-01)')
      expect(out.string).not_to include('more (see')
    end

    it 'flags a drive overdue for scrub once something has synced to it, but not an empty new one' do
      m = manifest
      m.record_sync(folder_path: 'Photos', drive_serial: 'S1', started_at: 't0', finished_at: 't1', exit_status: 0)
      m.close
      expect(cli('status').run).to eq(0)
      expect(out.string).to include('Overdue for `scrub`:', 'backup-01-3tb', 'never scrubbed')
      expect(out.string.scan('backup-02-6tb').size).to eq(1)   # only in the drive table, not the overdue list
    end

    it 'says scrubbing now instead of never scrubbed for the drive a running scrub is currently on' do
      m = manifest
      m.record_sync(folder_path: 'Photos', drive_serial: 'S1', started_at: 't0', finished_at: 't1', exit_status: 0)
      m.close
      lock_path = File.join(temp_dir, 'home', '.easy_sync', 'jbod.lock')
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.write(lock_path, "#{Process.pid}\nscrub\nbackup-01-3tb\n")

      expect(cli('status').run).to eq(0)
      expect(out.string).to include('backup-01-3tb', 'scrubbing now')
      expect(out.string).not_to include('never scrubbed')
    end

    it "shows this run's progress for a scrubbing drive, counting only files verified since the run started" do
      m = manifest
      m.reconcile_checksums('S1', 'Photos', { 'a.mkv' => [1, 1], 'b.mkv' => [1, 1] })
      # a.mkv was baselined by an earlier scrub, long before this run - it
      # must not count as "already checked" just because it has a digest.
      m.checksum_hashed('S1', 'Photos', 'a.mkv', outcome: :baseline, digest: 'old', at: '2020-01-01T00:00:00Z')
      m.close
      lock_path = File.join(temp_dir, 'home', '.easy_sync', 'jbod.lock')
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.write(lock_path, "#{Process.pid}\nscrub\nbackup-01-3tb\n")
      started = Time.utc(2026, 9, 22, 0, 0, 0)
      File.utime(started, started, lock_path)
      m2 = manifest
      m2.checksum_hashed('S1', 'Photos', 'b.mkv', outcome: :baseline, digest: 'new', at: (started + 5).utc.iso8601)
      m2.close

      expect(cli('status').run).to eq(0)
      expect(out.string).to include('Scrubbing now:', 'backup-01-3tb', '1/2 files checked (50%)')
    end

    it 'omits the Scrubbing now section entirely when nothing is currently scrubbing' do
      expect(cli('status').run).to eq(0)
      expect(out.string).not_to include('Scrubbing now:')
    end

    it 'never lists the same drive under both Overdue and Scrubbing now' do
      m = manifest
      # S1 is overdue and currently being scrubbed; S2 is overdue but idle.
      m.record_sync(folder_path: 'Photos', drive_serial: 'S1', started_at: 't0', finished_at: 't1', exit_status: 0)
      m.assign_folder('Videos', 'S2')
      m.record_sync(folder_path: 'Videos', drive_serial: 'S2', started_at: 't0', finished_at: 't1', exit_status: 0)
      m.close
      lock_path = File.join(temp_dir, 'home', '.easy_sync', 'jbod.lock')
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.write(lock_path, "#{Process.pid}\nscrub\nbackup-01-3tb\n")

      expect(cli('status').run).to eq(0)
      overdue_section = out.string[/Overdue for `scrub`:\n(.*?)\n\n/m, 1]
      expect(overdue_section).to include('backup-02-6tb')
      expect(overdue_section).not_to include('backup-01-3tb')
      expect(out.string).to include("Scrubbing now:\n  backup-01-3tb")
    end

    it 'reports the fleet-wide count of scrub findings, with a pointer to `scrub`' do
      m = manifest
      m.reconcile_checksums('S1', 'Photos', { 'a.jpg' => [1, 1] })
      m.checksum_hashed('S1', 'Photos', 'a.jpg', outcome: :corrupt, at: '2026-01-01T00:00:00Z')
      m.close
      expect(cli('status').run).to eq(0)
      expect(out.string).to include('1 file flagged by scrub', 'easy_sync scrub')
    end

    it 'says no sync is running when the lock file is absent' do
      expect(cli('status').run).to eq(0)
      expect(out.string).to include('No sync currently running.')
    end

    it 'shows a running sync and how long it has been running' do
      lock_path = File.join(temp_dir, 'home', '.easy_sync', 'jbod.lock')
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.write(lock_path, Process.pid.to_s)
      started = Time.utc(2026, 9, 13, 10, 0, 0)
      File.utime(started, started, lock_path)

      expect(cli('status', clock: double('clock', now: started + (2 * 3600) + (34 * 60))).run).to eq(0)
      expect(out.string).to include("Sync running: pid #{Process.pid}", '2h 34m ago')
    end

    it 'shows elapsed time in days once a run has been going that long' do
      lock_path = File.join(temp_dir, 'home', '.easy_sync', 'jbod.lock')
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.write(lock_path, Process.pid.to_s)
      started = Time.utc(2026, 9, 10, 10, 0, 0)
      File.utime(started, started, lock_path)

      expect(cli('status', clock: double('clock', now: started + (3 * 86_400) + (5 * 3600))).run).to eq(0)
      expect(out.string).to include('3d 5h ago')
    end

    it 'says Scrub running, not Sync, and omits the sync ETA, while a scrub holds the shared lock' do
      lock_path = File.join(temp_dir, 'home', '.easy_sync', 'jbod.lock')
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.write(lock_path, "#{Process.pid}\nscrub\n")
      started = Time.utc(2026, 9, 13, 10, 0, 0)
      File.utime(started, started, lock_path)

      expect(cli('status', clock: double('clock', now: started + (34 * 60))).run).to eq(0)
      expect(out.string).to include("Scrub running: pid #{Process.pid}", '34m 0s ago')
      expect(out.string).not_to include('Sync running', 'Estimating time remaining')
    end

    describe 'estimating time remaining for a sync in progress' do
      let(:lock_path) { File.join(temp_dir, 'home', '.easy_sync', 'jbod.lock') }
      let(:started) { Time.utc(2026, 9, 15, 8, 0, 0) }

      before do
        FileUtils.mkdir_p(File.dirname(lock_path))
        File.write(lock_path, Process.pid.to_s)
        File.utime(started, started, lock_path)
      end

      it 'says it is waiting when nothing has finished yet this run' do
        expect(cli('status', clock: double('clock', now: started + 5)).run).to eq(0)
        expect(out.string).to include('Estimating time remaining: still measuring/placing folders, or waiting on a large first copy to finish...')
      end

      it 'combines the observed transfer rate and verify time into one estimate' do
        m = manifest
        m.assign_folder('Movies/A', 'S1', size_bytes: 100 * GB)   # never synced, remains
        m.assign_folder('Movies/B', 'S1', size_bytes: 50 * GB)
        m.record_sync(folder_path: 'Movies/B', drive_serial: 'S1', started_at: '2026-01-01T00:00:00Z',
                      finished_at: '2026-01-01T00:00:01Z', exit_status: 0, bytes_transferred: 50 * GB, total_size_bytes: 50 * GB)
        # synced before this run, not yet re-touched -> remains as "to re-verify"
        m.assign_folder('Movies/C', 'S1', size_bytes: 200 * GB)
        # a real transfer this run: 20 GB in 20s = 1 GB/s
        m.record_sync(folder_path: 'Movies/C', drive_serial: 'S1', started_at: '2026-09-15T08:00:10Z',
                      finished_at: '2026-09-15T08:00:30Z', exit_status: 0, bytes_transferred: 20 * GB, total_size_bytes: 200 * GB)
        m.assign_folder('Movies/D', 'S1', size_bytes: 10 * GB)
        # a verify-only run this run: 2s, nothing transferred
        m.record_sync(folder_path: 'Movies/D', drive_serial: 'S1', started_at: '2026-09-15T08:00:31Z',
                      finished_at: '2026-09-15T08:00:33Z', exit_status: 0, bytes_transferred: 0, total_size_bytes: 10 * GB)
        m.close

        expect(cli('status', clock: double('clock', now: started + 40)).run).to eq(0)
        # remaining never-synced: Photos (from the outer before) + Movies/A = 2, at 1 GB/s that's 100s
        # remaining to re-verify: Movies/B = 1, at the observed 2s each
        expect(out.string).to include('About 1m 42s remaining (2 folders never synced, 1 to re-verify) - ' \
                                      'rough estimate, NAS/network speed varies.')
      end

      it 'says it is waiting for a first real transfer when only verifies have finished so far this run' do
        m = manifest
        m.assign_folder('Movies/Y', 'S1', size_bytes: 50 * GB)
        m.record_sync(folder_path: 'Movies/Y', drive_serial: 'S1', started_at: '2020-01-01T00:00:00Z',
                      finished_at: '2020-01-01T00:00:01Z', exit_status: 0, bytes_transferred: 50 * GB, total_size_bytes: 50 * GB)
        m.record_sync(folder_path: 'Movies/Y', drive_serial: 'S1', started_at: '2026-09-15T08:00:05Z',
                      finished_at: '2026-09-15T08:00:06Z', exit_status: 0, bytes_transferred: 0, total_size_bytes: 50 * GB)
        m.close

        expect(cli('status', clock: double('clock', now: started + 10)).run).to eq(0)
        # Photos (from the outer before) is the only folder never synced
        expect(out.string).to include('1 folder never synced (0 B); still waiting for one to finish before estimating their time.')
      end

      it 'shows no estimate once every folder has been touched this run' do
        m = manifest
        m.record_sync(folder_path: 'Photos', drive_serial: 'S1', started_at: '2026-09-15T08:00:01Z',
                      finished_at: '2026-09-15T08:00:02Z', exit_status: 0, bytes_transferred: 0, total_size_bytes: 10)
        m.close

        expect(cli('status', clock: double('clock', now: started + 5)).run).to eq(0)
        expect(out.string).not_to include('remaining', 'Estimating', 'waiting')
      end
    end
  end

  describe 'dashboard' do
    let(:dashboard_path) { File.join(temp_dir, 'dashboard.html') }

    it 'writes the file with no ETA banner when no sync is running' do
      expect(cli('dashboard').run).to eq(0)
      expect(out.string).to include("Dashboard written to #{dashboard_path}")
      expect(File.read(dashboard_path)).not_to include('class="eta"')
    end

    it 'includes an ETA banner, phrased the same way as `status`, while a sync is running' do
      lock_path = File.join(temp_dir, 'home', '.easy_sync', 'jbod.lock')
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.write(lock_path, Process.pid.to_s)
      File.utime(Time.now, Time.now, lock_path)

      expect(cli('dashboard').run).to eq(0)
      expect(File.read(dashboard_path)).to include('<p class="line">Sync in progress: Estimating time remaining: still measuring/placing folders, or waiting on a large first copy to finish...</p>')
    end

    it 'says Scrub in progress, not Sync, while a scrub holds the shared lock' do
      lock_path = File.join(temp_dir, 'home', '.easy_sync', 'jbod.lock')
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.write(lock_path, "#{Process.pid}\nscrub\n")
      File.utime(Time.now, Time.now, lock_path)

      expect(cli('dashboard').run).to eq(0)
      html = File.read(dashboard_path)
      expect(html).to match(/Scrub in progress \(started .* ago\)\./)
      expect(html).not_to include('Sync in progress')
    end
  end

  describe 'rename-drive' do
    def mount(serial, name)
      vol = make_dirs(mount_root, name).first
      write_file(File.join(vol, EasySync::Jbod::MARKER_FILE), { serial_number: serial, friendly_name: name }.to_json)
      fake_shell.on(->(argv) { argv[0] == 'df' && argv.last == vol }, output: df_output(vol, capacity_kb: 1_000_000, used_kb: 1_000))
      vol
    end

    before do
      m = manifest
      m.register_drive(serial_number: 'S1', friendly_name: 'backup-07-2tb', capacity_bytes: 2 * TB)
      m.register_drive(serial_number: 'S2', friendly_name: 'backup-08-6tb', capacity_bytes: 6 * TB)
      m.register_drive(serial_number: 'S3', friendly_name: 'backup-09-6tb', capacity_bytes: 6 * TB)
      m.retire_drive('S3')
      m.close
    end

    it 'relabels a single drive when the new name is free' do
      expect(cli('rename-drive', 'backup-07-2tb', 'backup-11-2tb').run).to eq(0)
      expect(manifest.drive_by_name('backup-11-2tb').serial_number).to eq('S1')
      expect(out.string).to include('Renamed backup-07-2tb to backup-11-2tb.')
      expect(out.string).not_to include('Swapped')
    end

    it 'swaps two names in one operation when the new name is already taken' do
      expect(cli('rename-drive', 'backup-07-2tb', 'backup-08-6tb').run).to eq(0)
      expect(manifest.drive_by_name('backup-08-6tb').serial_number).to eq('S1')
      expect(manifest.drive_by_name('backup-07-2tb').serial_number).to eq('S2')
      expect(out.string).to include('Swapped names: backup-07-2tb <-> backup-08-6tb.')
    end

    it 'rewrites the marker on any drive that is mounted, keeping the original registered_at' do
      vol = mount('S1', 'backup-07-2tb')
      write_file(File.join(vol, EasySync::Jbod::MARKER_FILE),
                { serial_number: 'S1', friendly_name: 'backup-07-2tb', registered_at: '2026-01-01T00:00:00Z' }.to_json)

      expect(cli('rename-drive', 'backup-07-2tb', 'backup-11-2tb').run).to eq(0)
      marker = JSON.parse(File.read(File.join(vol, EasySync::Jbod::MARKER_FILE)), symbolize_names: true)
      expect(marker).to include(serial_number: 'S1', friendly_name: 'backup-11-2tb', registered_at: '2026-01-01T00:00:00Z')
    end

    it 'suggests the diskutil rename command for each mounted drive involved, and nothing for an unmounted one' do
      mount('S1', 'backup-07-2tb')
      expect(cli('rename-drive', 'backup-07-2tb', 'backup-08-6tb').run).to eq(0)
      expect(out.string).to include("diskutil rename #{mount_root}/backup-07-2tb backup-08-6tb")
      expect(out.string).not_to include("diskutil rename #{mount_root}/backup-08-6tb backup-07-2tb")   # S2 was never mounted
    end

    it 'never touches the manifest when it cannot rename' do
      expect(cli('rename-drive', 'nope', 'x').run).to eq(1)
      expect(err.string).to include('no drive named nope')

      expect(cli('rename-drive', 'backup-09-6tb', 'backup-11-2tb').run).to eq(1)
      expect(err.string).to include('backup-09-6tb is retired')

      expect(cli('rename-drive', 'backup-07-2tb', 'backup-07-2tb').run).to eq(1)
      expect(err.string).to include('same')

      expect(manifest.drives.map(&:friendly_name)).to contain_exactly('backup-07-2tb', 'backup-08-6tb')
    end
  end

  describe 'verify-drive' do
    before do
      m = manifest
      m.register_drive(serial_number: 'S1', friendly_name: 'backup-02-6tb', capacity_bytes: 6 * TB)
      m.record_smart_check('S1', reallocated_sector_ct: 24)
      m.update_drive_health('S1', status: 'warning', detail: 'PASSED · reallocated 24 · 34°C')
      m.close
    end

    it 'records a verified-stable checkpoint and downgrades an active warning to degraded_stable' do
      expect(cli('verify-drive', 'backup-02-6tb', '--note', 'SpinRite Level 3, 0 new defects').run).to eq(0)
      expect(out.string).to include("Recorded backup-02-6tb's current reallocated-sector count as a verified-stable checkpoint.",
                                    'Note: SpinRite Level 3, 0 new defects')

      drive = manifest.drive_by_name('backup-02-6tb')
      expect(drive.smart_status).to eq('degraded_stable')
      expect(manifest.reallocated_baseline('S1')).to eq(24)
    end

    it 'fails for an unknown drive name' do
      expect(cli('verify-drive', 'nope').run).to eq(1)
      expect(err.string).to include('no drive named nope')
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
      expect(out.string).to include('Retired: backup-04-8tb (20', 'backup-00 (20')   # newest retirement first
      expect(out.string).to match(/unchecked[^\n]*\n\nTotal: [^\n]*\n\n {2}Retired: /)   # blank lines set the total and retired groups apart
      out.truncate(0)
      cli('history', 'movies/A').run
      expect(out.string).to include('reassigned', '-> backup-08-12tb', 'backup-04-8tb replaced by backup-08-12tb')
    end
  end

  describe 'restore' do
    let(:vol) { make_dirs(mount_root, 'backup-04-8tb').first }
    let(:tv) { make_dirs(temp_dir, 'nas-tv').first }

    before do
      write_file(File.join(vol, EasySync::Jbod::MARKER_FILE), '{"serial_number":"S1","friendly_name":"backup-04-8tb"}')
      fake_shell.on('df', output: df_output(vol, capacity_kb: 8_000_000, used_kb: 1_000))
      cfg = YAML.safe_load_file(config_path, permitted_classes: [Symbol], symbolize_names: true)
      File.write(config_path, cfg.merge(sources: [{ path: tv }]).to_yaml)
      m = manifest
      m.register_drive(serial_number: 'S1', friendly_name: 'backup-04-8tb', capacity_bytes: 8 * TB)
      m.assign_folder('nas-tv/Breaking Bad', 'S1')
      m.close
      write_file(File.join(vol, 'nas-tv', 'Breaking Bad', 'S01E01.mp4'), 'x' * 100)
    end

    it 'rsyncs a folder back onto its NAS share, with --partial and no --delete' do
      fake_shell.on('rsync', output: rsync_stats)
      expect(cli('restore', 'nas-tv/Breaking Bad').run).to eq(0)
      call = fake_shell.calls_to('rsync').first
      expect(call).to include('-a', '--partial')
      expect(call).not_to include('--delete')
      expect(call.last(2)).to eq(["#{File.join(vol, 'nas-tv/Breaking Bad')}/", "#{File.join(tv, 'Breaking Bad')}/"])
      expect(out.string).to include('Restored 1, skipped 0, failed 0')
    end

    it 'expands a share name to every folder placed under it' do
      fake_shell.on('rsync', output: rsync_stats)
      expect(cli('restore', 'nas-tv').run).to eq(0)
      expect(fake_shell.calls_to('rsync').size).to eq(1)
    end

    it 'refuses with no target and no --all' do
      expect(cli('restore').run).to eq(1)
      expect(err.string).to include('restore needs a folder or share name')
    end

    it 'errors on a name matching nothing placed' do
      expect(cli('restore', 'movies').run).to eq(1)
      expect(err.string).to include('movies matches no placed folder or share')
    end

    it '--all restores every folder in the manifest' do
      m = manifest
      m.assign_folder('nas-tv/Better Call Saul', 'S1')
      m.close
      write_file(File.join(vol, 'nas-tv', 'Better Call Saul', 'S01E01.mp4'))
      fake_shell.on('rsync', output: rsync_stats)
      expect(cli('restore', '--all').run).to eq(0)
      expect(fake_shell.calls_to('rsync').size).to eq(2)
    end

    it 'takes the sync lock for a real restore but not for --dry-run' do
      lock_path = File.join(temp_dir, 'jbod.lock')
      cfg = YAML.safe_load_file(config_path, permitted_classes: [Symbol], symbolize_names: true)
      File.write(config_path, cfg.merge(lock_path: lock_path).to_yaml)
      File.write(lock_path, Process.pid.to_s)
      fake_shell.on('rsync', output: rsync_stats)

      expect(cli('restore', 'nas-tv', '--dry-run').run).to eq(0)
      expect(out.string).to include('Would restore 1')
      expect(cli('restore', 'nas-tv').run).to eq(1)
      expect(err.string).to include('already running')
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

  describe 'scrub' do
    let(:vol) { make_dirs(mount_root, 'backup-01-3tb').first }

    def register_and_mount(serial:, name:, vol:)
      write_file(File.join(vol, EasySync::Jbod::MARKER_FILE), JSON.generate(serial_number: serial, friendly_name: name))
      fake_shell.on(->(argv) { argv[0] == 'df' && argv.last == vol }, output: df_output(vol, capacity_kb: 3_000_000, used_kb: 1_000))
      m = manifest
      m.register_drive(serial_number: serial, friendly_name: name, capacity_bytes: 3 * TB)
      m.close
    end

    it 'scrubs the stalest mounted drive when given no arguments, baselining every tracked file' do
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      write_file(File.join(vol, 'pro', 'a.mkv'), 'hello')
      m = manifest
      m.assign_folder('pro', 'S1')
      m.close

      expect(cli('scrub').run).to eq(0)
      rows = manifest.checksum_rows('S1', 'pro')
      expect(rows.size).to eq(1)
      expect(rows.first.digest).not_to be_nil
      expect(out.string).to include('backup-01-3tb:')
    end

    it 'notes which drive it is currently on, so `status` can say "scrubbing now" instead of guessing' do
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      vol2 = make_dirs(mount_root, 'backup-02-3tb').first
      register_and_mount(serial: 'S2', name: 'backup-02-3tb', vol: vol2)
      write_file(File.join(vol, 'pro', 'a.mkv'), 'hello')
      write_file(File.join(vol2, 'pro2', 'b.mkv'), 'world')
      m = manifest
      m.assign_folder('pro', 'S1')
      m.assign_folder('pro2', 'S2')
      m.close

      lock_path = File.join(temp_dir, 'home', '.easy_sync', 'jbod.lock')
      seen = []
      allow_any_instance_of(EasySync::Jbod::Scrubber).to receive(:run).and_wrap_original do |m2, *args|
        seen << File.read(lock_path).lines.map(&:strip)
        m2.call(*args)
      end

      expect(cli('scrub', '--all', '--jobs', '1').run).to eq(0)
      expect(seen).to eq([[Process.pid.to_s, 'scrub', 'backup-01-3tb'], [Process.pid.to_s, 'scrub', 'backup-02-3tb']])
    end

    it 'exits non-zero when a file ends the run corrupt, unreadable or unresolved' do
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      path = write_file(File.join(vol, 'pro', 'a.mkv'), 'hello world, a longer string')
      m = manifest
      m.assign_folder('pro', 'S1')
      m.close
      cli('scrub').run
      mtime = File.mtime(path)
      File.open(path, 'r+b') { |f| f.write('X') }
      File.utime(mtime, mtime, path)

      expect(cli('scrub').run).to eq(1)
      expect(out.string).to include('CORRUPT')
    end

    it 'refuses an unknown or retired drive name' do
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      expect(cli('scrub', 'nope').run).to eq(1)
      expect(err.string).to include('no drive named nope')

      m = manifest
      m.retire_drive('S1')
      m.close
      expect(cli('scrub', 'backup-01-3tb').run).to eq(1)
      expect(err.string).to include('is retired')
    end

    it 'scrubs every mounted, non-retired drive with --all' do
      vol2 = make_dirs(mount_root, 'backup-02-6tb').first
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      register_and_mount(serial: 'S2', name: 'backup-02-6tb', vol: vol2)
      write_file(File.join(vol, 'pro', 'a.mkv'))
      write_file(File.join(vol2, 'stuff', 'b.mkv'))
      m = manifest
      m.assign_folder('pro', 'S1')
      m.assign_folder('stuff', 'S2')
      m.close

      expect(cli('scrub', '--all').run).to eq(0)
      expect(manifest.checksum_rows('S1', 'pro').size).to eq(1)
      expect(manifest.checksum_rows('S2', 'stuff').size).to eq(1)
    end

    it 'with no arguments picks the stalest mounted drive, and a never-scrubbed one beats every other drive' do
      vol2 = make_dirs(mount_root, 'backup-02-6tb').first
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      register_and_mount(serial: 'S2', name: 'backup-02-6tb', vol: vol2)
      write_file(File.join(vol, 'pro', 'a.mkv'))
      write_file(File.join(vol2, 'stuff', 'b.mkv'))
      m = manifest
      m.assign_folder('pro', 'S1')
      m.assign_folder('stuff', 'S2')
      # backup-01-3tb was already scrubbed recently; backup-02-6tb never has,
      # so it must be picked even though it's alphabetically second.
      m.reconcile_checksums('S1', 'pro', { 'a.mkv' => [1, 1] })
      m.checksum_hashed('S1', 'pro', 'a.mkv', outcome: :baseline, digest: 'x', at: '2026-09-13T00:00:00Z')
      m.close

      expect(cli('scrub').run).to eq(0)
      expect(manifest.checksum_rows('S2', 'stuff').size).to eq(1)   # backup-02-6tb was scrubbed
      expect(manifest.checksum_rows('S1', 'pro').first.verified_at).to eq('2026-09-13T00:00:00Z')   # backup-01-3tb was not touched again
    end

    it '--all goes through the drives stalest first' do
      vol2 = make_dirs(mount_root, 'backup-02-6tb').first
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      register_and_mount(serial: 'S2', name: 'backup-02-6tb', vol: vol2)
      write_file(File.join(vol, 'pro', 'a.mkv'))
      write_file(File.join(vol2, 'stuff', 'b.mkv'))
      m = manifest
      m.assign_folder('pro', 'S1')
      m.assign_folder('stuff', 'S2')
      m.reconcile_checksums('S1', 'pro', { 'a.mkv' => [1, 1] })
      m.checksum_hashed('S1', 'pro', 'a.mkv', outcome: :baseline, digest: 'x', at: '2026-09-13T00:00:00Z')
      m.close

      cli('scrub', '--all', '--jobs', '1').run
      order = out.string.scan(/^backup-0[12]-\w+tb:/).map { |l| l.delete_suffix(':') }
      expect(order).to eq(['backup-02-6tb', 'backup-01-3tb'])   # never-scrubbed first
    end

    it 'scrubs named drives in the order given, regardless of staleness' do
      vol2 = make_dirs(mount_root, 'backup-02-6tb').first
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      register_and_mount(serial: 'S2', name: 'backup-02-6tb', vol: vol2)
      write_file(File.join(vol, 'pro', 'a.mkv'))
      write_file(File.join(vol2, 'stuff', 'b.mkv'))
      m = manifest
      m.assign_folder('pro', 'S1')
      m.assign_folder('stuff', 'S2')
      m.close

      cli('scrub', 'backup-01-3tb', 'backup-02-6tb', '--jobs', '1').run
      order = out.string.scan(/^backup-0[12]-\w+tb:/).map { |l| l.delete_suffix(':') }
      expect(order).to eq(['backup-01-3tb', 'backup-02-6tb'])
    end

    it 'refuses a second concurrent run, sharing the lock with sync' do
      lock_path = File.join(temp_dir, 'jbod.lock')
      cfg = YAML.safe_load_file(config_path, permitted_classes: [Symbol], symbolize_names: true)
      File.write(config_path, cfg.merge(lock_path: lock_path).to_yaml)
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      File.write(lock_path, Process.pid.to_s)

      expect(cli('scrub').run).to eq(1)
      expect(err.string).to include('already running')
    end

    it 'writes its own scrub-*.log, kept separate from sync-*.log' do
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      cli('scrub').run
      expect(Dir.glob(File.join(temp_dir, 'logs', 'scrub-*.log')).size).to eq(1)
      expect(Dir.glob(File.join(temp_dir, 'logs', 'sync-*.log'))).to be_empty
      expect(File.read(Dir.glob(File.join(temp_dir, 'logs', 'scrub-*.log')).first)).to include('easy_sync 2.0.0 scrub')
    end

    it 'says the scrub stopped early, not that it finished, when the drive disappears mid-run' do
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      write_file(File.join(vol, 'pro', 'a.mkv'))
      m = manifest
      m.assign_folder('pro', 'S1')
      m.close
      allow_any_instance_of(EasySync::Jbod::Scrubber).to receive(:marker_present?).and_return(false)

      expect(cli('scrub').run).to eq(0)
      expect(out.string).to include('Scrub stopped early (backup-01-3tb was unmounted)')
      expect(out.string).not_to include('ran to completion')
    end

    it 'does not hash or write anything in --dry-run' do
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      write_file(File.join(vol, 'pro', 'a.mkv'))
      m = manifest
      m.assign_folder('pro', 'S1')
      m.close

      expect(cli('scrub', '--dry-run').run).to eq(0)
      expect(manifest.checksum_rows('S1', 'pro')).to be_empty
      expect(out.string).to include('DRY RUN')
    end

    it 'refuses when no mounted drive is available' do
      expect(cli('scrub').run).to eq(1)
      expect(err.string).to include('no mounted, non-retired drive to scrub')
    end

    it 'rejects --jobs 0 and a non-integer --jobs' do
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      expect(cli('scrub', '--jobs', '0').run).to eq(1)
      expect(err.string).to include('positive integer')

      expect(cli('scrub', '--jobs', '-1').run).to eq(1)
      expect(cli('scrub', '--jobs', 'x').run).to eq(1)
    end

    it 'scrubs every mounted drive with --jobs 2 --all' do
      vol2 = make_dirs(mount_root, 'backup-02-6tb').first
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      register_and_mount(serial: 'S2', name: 'backup-02-6tb', vol: vol2)
      write_file(File.join(vol, 'pro', 'a.mkv'))
      write_file(File.join(vol2, 'stuff', 'b.mkv'))
      m = manifest
      m.assign_folder('pro', 'S1')
      m.assign_folder('stuff', 'S2')
      m.close

      expect(cli('scrub', '--all', '--jobs', '2').run).to eq(0)
      expect(manifest.checksum_rows('S1', 'pro').size).to eq(1)
      expect(manifest.checksum_rows('S2', 'stuff').size).to eq(1)
      expect(out.string).to include('· jobs 2 ·')
    end

    it 'status shows every drive a multi-line lock file names as scrubbing now, and print_run_status lists them' do
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      vol2 = make_dirs(mount_root, 'backup-02-3tb').first
      register_and_mount(serial: 'S2', name: 'backup-02-3tb', vol: vol2)
      m = manifest
      m.assign_folder('pro', 'S1')
      m.assign_folder('stuff', 'S2')
      m.record_sync(folder_path: 'pro', drive_serial: 'S1', started_at: 't0', finished_at: 't1', exit_status: 0)
      m.record_sync(folder_path: 'stuff', drive_serial: 'S2', started_at: 't0', finished_at: 't1', exit_status: 0)
      m.close
      lock_path = File.join(temp_dir, 'home', '.easy_sync', 'jbod.lock')
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.write(lock_path, "#{Process.pid}\nscrub\nbackup-01-3tb\nbackup-02-3tb\n")

      expect(cli('status').run).to eq(0)
      expect(out.string.scan('scrubbing now').size).to eq(2)
      expect(out.string).to include('Scrub running: pid', 'on backup-01-3tb, backup-02-3tb')
    end
  end

  describe 'benchmark' do
    let(:vol) { make_dirs(mount_root, 'backup-01-3tb').first }
    let(:lock_path) { File.join(temp_dir, 'home', '.easy_sync', 'jbod.lock') }

    def register_and_mount(serial:, name:, vol:, used_kb: 1_000)
      write_file(File.join(vol, EasySync::Jbod::MARKER_FILE), JSON.generate(serial_number: serial, friendly_name: name))
      fake_shell.on(->(argv) { argv[0] == 'df' && argv.last == vol },
                    output: df_output(vol, capacity_kb: 3_000_000, used_kb: used_kb))
      m = manifest
      m.register_drive(serial_number: serial, friendly_name: name, capacity_bytes: 3 * TB)
      m.close
    end

    def record(serial, write:, read:, day:)
      m = manifest
      m.record_benchmark(serial, bytes: 8 * GB, write_mb_s: write, read_mb_s: read, used_bytes: TB,
                                 at: format('2026-09-%02dT12:00:00Z', day))
      m.close
    end

    # 1 MiB in 1/100 s each way: 100 MB/s.
    def stub_rates(write_seconds: 0.01, read_seconds: 0.01)
      allow_any_instance_of(EasySync::Jbod::Benchmarker).to receive(:run) do |_, mounted, size:|
        EasySync::Jbod::Benchmarker::Result.new(drive: mounted.friendly_name, bytes: size, used_bytes: mounted.used_bytes,
                                                write_seconds: write_seconds, read_seconds: read_seconds)
      end
    end

    it 'writes and reads back a test file on the named drive, records the result, and leaves nothing behind' do
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)

      expect(cli('benchmark', 'backup-01-3tb', '--size', '1mb').run).to eq(0)
      runs = manifest.benchmarks('S1')
      expect(runs.size).to eq(1)
      expect(runs.first).to have_attributes(bytes: 1024 * 1024, used_bytes: 1_000 * 1024)
      expect(runs.first.write_mb_s).to be_positive
      expect(out.string).to include('backup-01-3tb: writing 1.0 MB', 'First run for this drive')
      expect(Dir.children(File.join(vol, EasySync::Jbod::DRIVE_DIR))).to eq(['drive.json'])
      expect(File.exist?(lock_path)).to be(false)
    end

    it 'with no arguments benchmarks the mounted drive benchmarked longest ago, never-benchmarked first' do
      vol2 = make_dirs(mount_root, 'backup-02-3tb').first
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      register_and_mount(serial: 'S2', name: 'backup-02-3tb', vol: vol2)
      record('S1', write: 100, read: 100, day: 1)
      stub_rates

      expect(cli('benchmark', '--size', '1mb').run).to eq(0)
      expect(manifest.benchmarks('S2').size).to eq(1)
      expect(manifest.benchmarks('S1').size).to eq(1)
    end

    it 'benchmarks every mounted drive one at a time with --all, noting the current one in the lock' do
      vol2 = make_dirs(mount_root, 'backup-02-3tb').first
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      register_and_mount(serial: 'S2', name: 'backup-02-3tb', vol: vol2)
      seen = []
      allow_any_instance_of(EasySync::Jbod::Benchmarker).to receive(:run) do |_, mounted, size:|
        seen << File.read(lock_path).lines.map(&:strip)
        EasySync::Jbod::Benchmarker::Result.new(drive: mounted.friendly_name, bytes: size, used_bytes: 0,
                                                write_seconds: 1, read_seconds: 1)
      end

      expect(cli('benchmark', '--all', '--size', '1mb').run).to eq(0)
      expect(seen).to eq([[Process.pid.to_s, 'benchmark', 'backup-01-3tb'], [Process.pid.to_s, 'benchmark', 'backup-02-3tb']])
    end

    it "compares a run against the drive's earlier ones and exits 1 when it is well below their median" do
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      (1..3).each { |day| record('S1', write: 200, read: 100, day: day) }
      stub_rates   # 100 MB/s both ways: write -50%, read unchanged

      expect(cli('benchmark', 'backup-01-3tb', '--size', '1mb').run).to eq(1)
      expect(out.string).to include('vs. median of 3 earlier runs: write 200.0 MB/s (-50%), read 100.0 MB/s (+0%)',
                                    'SLOWER than usual (write)')
    end

    it 'does not flag a slowdown with fewer earlier runs than it needs, and says so' do
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      record('S1', write: 200, read: 200, day: 1)
      stub_rates

      expect(cli('benchmark', 'backup-01-3tb', '--size', '1mb').run).to eq(0)
      expect(out.string).to include('vs. median of 1 earlier run:', 'only flagged from 3 earlier runs on')
      expect(out.string).not_to include('SLOWER')
    end

    it 'skips a drive without room for the test file plus the reserve, without failing' do
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol, used_kb: 2_000_000)   # ~0.95 GB free, 2 GB reserve

      expect(cli('benchmark', 'backup-01-3tb', '--size', '1mb').run).to eq(0)
      expect(out.string).to include('backup-01-3tb: skipped', 'a smaller --size fits')
      expect(manifest.benchmarks('S1')).to eq([])
    end

    it 'exits 1 and records nothing when the drive fails mid-run' do
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      allow_any_instance_of(EasySync::Jbod::Benchmarker).to receive(:run) do |_, mounted, size:|
        EasySync::Jbod::Benchmarker::Result.new(drive: mounted.friendly_name, bytes: size, error: 'unmounted mid-run')
      end

      expect(cli('benchmark', 'backup-01-3tb', '--size', '1mb').run).to eq(1)
      expect(out.string).to include('FAILED: unmounted mid-run')
      expect(manifest.benchmarks('S1')).to eq([])
    end

    it 'lists the kept runs with --history, including drives never benchmarked, without taking the lock' do
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      m = manifest
      m.register_drive(serial_number: 'S2', friendly_name: 'backup-02-3tb', capacity_bytes: 3 * TB)
      m.close
      record('S1', write: 180.25, read: 190, day: 1)
      record('S1', write: 181, read: 191, day: 2)
      File.write(lock_path.tap { |p| FileUtils.mkdir_p(File.dirname(p)) }, "#{Process.pid}\nsync\n")

      expect(cli('benchmark', '--history').run).to eq(0)
      expect(out.string).to include('backup-01-3tb (2 runs, newest first):', '181.0 MB/s', '180.2 MB/s', '8.0 GB',
                                    'backup-02-3tb: never benchmarked')
      expect(out.string.index('181.0 MB/s')).to be < out.string.index('180.2 MB/s')
    end

    it 'refuses to run while another run holds the lock' do
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      File.write(lock_path.tap { |p| FileUtils.mkdir_p(File.dirname(p)) }, "#{Process.pid}\nsync\n")

      expect(cli('benchmark', 'backup-01-3tb').run).to eq(1)
      expect(err.string).to include('already running')
    end

    it 'refuses names together with --all, an unknown or retired drive, and a bad --size' do
      register_and_mount(serial: 'S1', name: 'backup-01-3tb', vol: vol)
      expect(cli('benchmark', 'backup-01-3tb', '--all').run).to eq(1)
      expect(err.string).to include('not both')
      expect(cli('benchmark', 'nope').run).to eq(1)
      expect(err.string).to include('no drive named nope')
      expect(cli('benchmark', 'backup-01-3tb', '--size', 'lots').run).to eq(1)
      expect(err.string).to include('cannot parse size')

      m = manifest
      m.retire_drive('S1')
      m.close
      expect(cli('benchmark', 'backup-01-3tb').run).to eq(1)
      expect(err.string).to include('is retired')
    end
  end

  describe 'add-source / remove-source / sources' do
    let(:tv) { make_dirs(File.join(temp_dir, 'shares'), 'tv').first }

    before { make_dirs(tv, 'Show A', 'Show B') }

    it 'adds a share and lists it' do
      expect(cli('add-source', tv).run).to eq(0)
      expect(out.string).to include("Added #{tv}. Config:")
      expect(EasySync::Config.load(config_path).first.source_entries.last).to eq({ path: tv })
      out.truncate(0); out.rewind
      cli('sources').run
      expect(out.string).to include(tv, 'mounted')
    end

    it 'refuses an unmounted or duplicate share, and removes one without touching drives' do
      expect(cli('add-source', File.join(temp_dir, 'nope')).run).to eq(1)
      expect(err.string).to include('not mounted')
      cli('add-source', tv).run
      expect(cli('add-source', tv).run).to eq(1)
      expect(err.string).to include('already a source')
      expect(cli('remove-source', tv).run).to eq(0)
      expect(out.string).to include("Removed #{tv}. Nothing on the drives was touched")
      expect(EasySync::Config.load(config_path).first.source_entries.map { |e| e[:path] }).not_to include(tv)
    end
  end

  describe 'sync' do
    def merge_sync_config(**overrides)
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
      merge_sync_config(lock_path: lock_path)
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.write(lock_path, Process.pid.to_s) # simulate a live concurrent run
      fake_shell.on('rsync', output: "rsync  version 3.5.0  protocol version 32\n")

      expect(cli('sync').run).to eq(1)
      expect(err.string).to include('already running', "pid #{Process.pid}")
      expect(File.read(lock_path)).to eq(Process.pid.to_s)
    end

    it 'keeps the Mac awake for the run unless told not to' do
      merge_sync_config(sources: [])
      fake_shell.on('rsync', output: "rsync  version 3.5.0  protocol version 32\n")
      allow(keep_awake).to receive(:start).and_return(true)

      cli('sync').run
      expect(keep_awake).to have_received(:start).once
      expect(out.string).to include('Keeping the Mac awake for this run (caffeinate).')

      cli('sync', '--no-keep-awake').run
      expect(keep_awake).to have_received(:start).once   # not called again
    end

    it 'respects keep_awake: false in the config' do
      merge_sync_config(sources: [], keep_awake: false)
      fake_shell.on('rsync', output: "rsync  version 3.5.0  protocol version 32\n")
      cli('sync').run
      expect(keep_awake).not_to have_received(:start)
    end

    describe '--accept-changes' do
      let(:runner) { instance_double(EasySync::Jbod::Runner) }
      let(:report) { EasySync::Jbod::Runner::Report.new }

      before do
        merge_sync_config(sources: [])
        fake_shell.on('rsync', output: "rsync  version 3.5.0  protocol version 32\n")
        allow(EasySync::Jbod::Runner).to receive(:new).and_return(runner)
        allow(runner).to receive(:run).and_return(report)
      end

      it 'passes nothing by default, true on its own, and folder names when given' do
        cli('sync').run
        cli('sync', '--accept-changes').run
        cli('sync', '--accept-changes', 'music/Jazz/', 'tv/Show').run
        expect(EasySync::Jbod::Runner).to have_received(:new).with(anything, hash_including(accept_changes: nil)).ordered
        expect(EasySync::Jbod::Runner).to have_received(:new).with(anything, hash_including(accept_changes: true)).ordered
        expect(EasySync::Jbod::Runner).to have_received(:new)
          .with(anything, hash_including(accept_changes: ['music/Jazz', 'tv/Show'])).ordered
      end

      it 'refuses folder names without --accept-changes' do
        expect(cli('sync', 'music/Jazz').run).to eq(1)
        expect(err.string).to include('unexpected argument music/Jazz')
      end

      it 'exits non-zero when the tripwire held something back, but not on a dry run' do
        report.tripped = ['music/Jazz']
        expect(cli('sync').run).to eq(1)
        expect(err.string).to include('the tripwire held back music/Jazz')
        expect(cli('sync', '--dry-run').run).to eq(0)

        report.run_tripped = true
        expect(cli('sync').run).to eq(1)
        expect(err.string).to include('the tripwire stopped this sync')
      end
    end

    it 'releases the lock after a run so a later sync can proceed' do
      lock_path = File.join(temp_dir, 'jbod.lock')
      merge_sync_config(lock_path: lock_path, sources: [])
      fake_shell.on('rsync', output: "rsync  version 3.5.0  protocol version 32\n")

      cli('sync').run # fails fast (no sources configured), but the lock must still be released
      expect(File).not_to exist(lock_path)
    end
  end

  describe 'pending' do
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

    it 'describes a reassigned folder distinctly, not as a missing-runs candidate' do
      m = manifest
      m.register_drive(serial_number: 'S1', friendly_name: 'backup-01-3tb', capacity_bytes: 3 * TB)
      m.register_drive(serial_number: 'S2', friendly_name: 'backup-02-6tb', capacity_bytes: 6 * TB)
      m.assign_folder('photos', 'S1')
      m.reassign_folder('photos', 'S2')
      m.close

      expect(cli('pending').run).to eq(0)
      expect(out.string).to include('photos (whole folder)', 'old copy on backup-01-3tb',
                                    'waiting for a verified sync to its new drive')
      expect(out.string).not_to include('seen missing')
    end

    it 'shows a reassigned folder as verified, with an expiry date, once its new drive has synced ok' do
      m = manifest
      m.register_drive(serial_number: 'S1', friendly_name: 'backup-01-3tb', capacity_bytes: 3 * TB)
      m.register_drive(serial_number: 'S2', friendly_name: 'backup-02-6tb', capacity_bytes: 6 * TB)
      m.assign_folder('photos', 'S1')
      m.reassign_folder('photos', 'S2')
      m.mark_folder_status('photos', 'ok')
      m.close

      expect(cli('pending').run).to eq(0)
      expect(out.string).to include('verified on its new drive', 'old copy on backup-01-3tb goes on')
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

  describe 'eject' do
    let(:clock) { double(now: Time.utc(2026, 9, 26, 12, 0)) }
    let(:lock_path) { File.join(temp_dir, 'home', '.easy_sync', 'jbod.lock') }
    let(:disks) { { 'backup-01-3tb' => 'disk4', 'backup-02-6tb' => 'disk6', 'backup-03-8tb' => 'disk8' } }

    before do
      m = manifest
      disks.each_key.with_index do |name, i|
        m.register_drive(serial_number: "S#{i + 1}", friendly_name: name, capacity_bytes: 3 * TB)
        m.update_drive_usage("S#{i + 1}", used_bytes: 1, free_bytes: 1, seen_at: '2026-09-01T00:00:00Z')
      end
      m.close
      # backup-01 and backup-02 are connected; backup-03 is not.
      %w[backup-01-3tb backup-02-6tb].each_with_index do |name, i|
        vol = make_dirs(mount_root, name).first
        write_file(File.join(vol, EasySync::Jbod::MARKER_FILE), { serial_number: "S#{i + 1}", friendly_name: name }.to_json)
        fake_shell.on(->(argv) { argv == ['diskutil', 'info', vol] }, output: "Part of Whole: #{disks[name].succ}\n")
        fake_shell.on(->(argv) { argv == ['diskutil', 'info', disks[name].succ] },
                      output: "APFS Physical Store: #{disks[name]}s2\n")
      end
      fake_shell.on('df', output: ->(argv) { df_output(argv.last, capacity_kb: 3 * 1024**3, used_kb: 1024) })
      # A real eject makes the volume vanish from /Volumes.
      fake_shell.on(->(argv) { argv[0, 2] == %w[diskutil eject] }, output: lambda { |argv|
        FileUtils.rm_rf(File.join(mount_root, disks.key(argv.last)))
        "Disk #{argv.last} ejected\n"
      })
    end

    def seen(name) = manifest.drive_by_name(name).last_seen_at

    it 'ejects the physical disk under every connected drive and says when to connect them again' do
      expect(cli('eject', clock: clock).run).to eq(0)
      expect(fake_shell.calls.select { |a| a[0, 2] == %w[diskutil eject] }).to eq([%w[diskutil eject disk4], %w[diskutil eject disk6]])
      expect(out.string).to include('Ejected backup-01-3tb (disk4)', 'Ejected backup-02-6tb (disk6)',
                                    'All 2 drives are ejected; it is safe to power off the enclosure.',
                                    'Connect again by 2026-10-26: Backblaze drops a drive')
      expect(seen('backup-01-3tb')).to be > '2026-09-01T00:00:00Z'
      expect(seen('backup-03-8tb')).to eq('2026-09-01T00:00:00Z')   # not connected, so not seen
      expect(File.read(File.join(temp_dir, 'dashboard.html'))).to include('not connected')
      expect(File).not_to exist(lock_path)
    end

    it 'ejects only the drives named, and says so for a name it cannot eject' do
      expect(cli('eject', 'backup-02-6tb').run).to eq(0)
      expect(out.string).to include('Ejected backup-02-6tb', 'The drive is ejected')
      expect(out.string).not_to include('backup-01-3tb')

      expect(cli('eject', 'backup-03-8tb').run).to eq(1)
      expect(err.string).to include('backup-03-8tb is not connected')
      expect(cli('eject', 'nope').run).to eq(1)
      expect(err.string).to include('no drive named nope')
    end

    it 'keeps the enclosure powered while a drive is still in use, naming what holds it' do
      fake_shell.on(->(argv) { argv == %w[diskutil eject disk6] }, status: 1, output: <<~OUT)
        Unmount of disk6 failed: at least one volume could not be unmounted
        Unmount was dissented by PID 812 (/Library/Backblaze.bzpkg/bztransmit)
        Dissenter parent PPID 1 (/sbin/launchd)
      OUT
      expect(cli('eject').run).to eq(1)
      expect(out.string).to include('Ejected backup-01-3tb (disk4)',
                                    'Could not eject backup-02-6tb: in use by pid 812 (/Library/Backblaze.bzpkg/bztransmit)',
                                    'backup-02-6tb still connected: do not power off yet.')
      expect(out.string).not_to include('safe to power off', 'Connect again')
    end

    it 'refuses while a sync is running' do
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.write(lock_path, "#{Process.pid}\nsync\n")
      expect(cli('eject').run).to eq(1)
      expect(err.string).to include("sync is running (pid #{Process.pid}); ejecting now would cut it off")
      expect(fake_shell.calls.select { |a| a[0, 2] == %w[diskutil eject] }).to be_empty
    end

    it 'with --dry-run lists the drives and changes nothing' do
      expect(cli('eject', '--dry-run').run).to eq(0)
      expect(out.string).to include('Would eject backup-01-3tb', 'Would eject backup-02-6tb', 'Dry run: nothing ejected.')
      expect(fake_shell.calls.select { |a| a[0, 2] == %w[diskutil eject] }).to be_empty
      expect(seen('backup-01-3tb')).to eq('2026-09-01T00:00:00Z')
      expect(File).not_to exist(File.join(temp_dir, 'dashboard.html'))
    end

    it 'says so when no drive is connected' do
      disks.each_key { |name| FileUtils.rm_rf(File.join(mount_root, name)) }
      expect(cli('eject').run).to eq(0)
      expect(out.string).to include('No easy_sync drive is connected; nothing to eject.')
    end
  end

  describe 'forget-drive' do
    before do
      m = manifest
      m.register_drive(serial_number: 'T1', friendly_name: 'jbod-test-1', capacity_bytes: TB)
      m.register_drive(serial_number: 'T2', friendly_name: 'jbod-test-2', capacity_bytes: TB)
      m.register_drive(serial_number: 'S1', friendly_name: 'backup-01-3tb', capacity_bytes: 3 * TB)
      m.assign_folder('Photos', 'T1')
      m.move_all_folders('T1', 'S1', note: 'replaced')
      m.retire_drive('T1')
      m.retire_drive('T2')
      m.close
    end

    it 'deletes retired drives and their history, so status no longer lists them' do
      expect(cli('forget-drive', 'jbod-test-1', 'jbod-test-2').run).to eq(0)
      expect(out.string).to include('Forgot jbod-test-1 (T1) and its rows: 1 placement_history.', 'Forgot jbod-test-2 (T2).')
      expect(manifest.drives(include_retired: true).map(&:friendly_name)).to eq(['backup-01-3tb'])
      expect(manifest.folder('Photos').drive_serial).to eq('S1')
      out.truncate(0)
      cli('status').run
      expect(out.string).not_to include('Retired', 'jbod-test')
    end

    it 'deletes nothing with --dry-run' do
      expect(cli('forget-drive', 'jbod-test-1', '--dry-run').run).to eq(0)
      expect(out.string).to include('Would forget jbod-test-1 (T1) and its rows: 1 placement_history.', 'nothing deleted')
      expect(manifest.drive('T1')).not_to be_nil
    end

    it 'checks every name before deleting any' do
      expect(cli('forget-drive', 'jbod-test-1', 'backup-01-3tb').run).to eq(1)
      expect(err.string).to include('backup-01-3tb is not retired')
      expect(manifest.drive('T1')).not_to be_nil
    end
  end

  describe 'status with a locked drive' do
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

  describe 'plan' do
    it 'prints measurements per share and whether every folder fits, without touching the config' do
      nas = make_dirs(temp_dir, 'nas').first
      make_dirs(nas, 'A', 'B')
      fake_shell.on('du', output: ->(argv) { argv[2..].map { |p| "#{9 * 1024 * 1024 * 1024}\t#{p}\n" }.join })
      before = File.read(config_path)
      expect(cli('plan', '--largest-drive', '8tb').run).to eq(0)
      expect(out.string).to include('Judging against the largest drive: 8.0 TB', '18.0 TB in 2 folders, largest A (9.0 TB)',
                                    'bigger than the largest drive currently registered', 'will fit once you add a bigger drive')
      expect(out.string).not_to include('split', '--apply')
      expect(File.read(config_path)).to eq(before)
      expect(cli('plan', '--apply').run).to eq(1)
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
      File.write(config_path, cfg.merge(sources: [{ path: pro }, { path: movies }]).to_yaml)
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
    logs = Dir.glob(File.join(temp_dir, 'logs', 'sync-*.log'))
    expect(logs.size).to eq(1)
    # The log itself must say so - otherwise the only way to tell an
    # interrupted run from a completed one is comparing two log files by eye.
    expect(File.read(logs.first)).to include('Sync interrupted (Ctrl-C)')
  end

  it 'turns a missing shell command into a calm error instead of a crash, releasing the lock' do
    lock_path = File.join(temp_dir, 'jbod.lock')
    cfg = YAML.safe_load_file(config_path, permitted_classes: [Symbol], symbolize_names: true)
    File.write(config_path, cfg.merge(lock_path: lock_path, sources: [File.join(temp_dir, 'nas')]).to_yaml)
    make_dirs(temp_dir, 'nas', 'nas/photos')
    write_file(File.join(temp_dir, 'nas', 'photos', 'x.jpg'))
    fake_shell.on('rsync', output: "rsync  version 3.5.0  protocol version 32\n")
    fake_shell.on('du', output: ->(_) { raise Errno::ENOENT, 'No such file or directory - du' })

    expect(cli('sync').run).to eq(1)
    expect(err.string).to include('error:', 'No such file or directory', 'du')
    expect(File).not_to exist(lock_path)
  end

  it 'marks the log as finished when a sync runs to completion, unlike an interrupted one' do
    cfg = YAML.safe_load_file(config_path, permitted_classes: [Symbol], symbolize_names: true)
    File.write(config_path, cfg.merge(sources: [File.join(temp_dir, 'nas')]).to_yaml)
    make_dirs(temp_dir, 'nas', 'nas/photos')
    write_file(File.join(temp_dir, 'nas', 'photos', 'x.jpg'))
    fake_shell.on('rsync', output: "rsync  version 3.5.0  protocol version 32\n")
    fake_shell.on('du', output: "10\t.\n")
    # No drives registered: the folder is left unplaced, but the run still
    # completes normally rather than raising - unlike an unmounted *source*.

    expect(cli('sync').run).to eq(0)
    log = File.read(Dir.glob(File.join(temp_dir, 'logs', 'sync-*.log')).first)
    expect(log).to include('Sync finished (ran to completion, not interrupted)')
    expect(log).not_to include('Sync interrupted')
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

    EasySync::Config.load(config_path).first.tap { |c| c.add_source('/Volumes/x'); c.save }
    out.truncate(0); out.rewind
    cli.run
    expect(out.string).not_to include('Nothing is configured yet')
  end
end
