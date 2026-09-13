# frozen_string_literal: true

RSpec.describe EasySync::CLI do
  let(:config_path) { File.join(temp_dir, 'rc.yml') }
  let(:mount_root) { File.join(temp_dir, 'Volumes') }
  let(:manifest_path) { File.join(temp_dir, 'manifest.sqlite3') }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  before do
    FileUtils.mkdir_p(mount_root)
    File.write(config_path, { logging: :off, tasks: [],
                              jbod: { mount_root: mount_root, manifest_path: manifest_path,
                                      sources: [File.join(temp_dir, 'nas')],
                                      dashboard_path: File.join(temp_dir, 'dashboard.html') } }.to_yaml)
  end

  def cli(*args)
    described_class.new(args, out: out, err: err, config_path: config_path, shell: fake_shell)
  end

  def manifest = EasySync::Jbod::Manifest.open(manifest_path)

  describe 'jbod register-drive' do
    let(:vol) { make_dirs(mount_root, 'backup-04-8tb').first }

    before do
      fake_shell.on('df', output: df_output(vol, capacity_kb: 8_000_000, used_kb: 1_000))
      fake_shell.on('diskutil', output: "   Volume UUID:               ABCD-1234\n")
    end

    it 'registers the drive using the Volume UUID and writes a marker' do
      expect(cli('jbod', 'register-drive', vol).run).to eq(0)
      drive = manifest.drives.first
      expect(drive).to have_attributes(serial_number: 'ABCD-1234', friendly_name: 'backup-04-8tb',
                                       capacity_bytes: 8_000_000 * 1024, volume_uuid: 'ABCD-1234',
                                       last_used_bytes: 1_000 * 1024)
      expect(JSON.parse(File.read(File.join(vol, EasySync::Jbod::MARKER_FILE)))['serial_number']).to eq('ABCD-1234')
      expect(out.string).to include('Registered backup-04-8tb (ABCD-1234)')
    end

    it 'prefers an explicit --serial and --name' do
      cli('jbod', 'register-drive', vol, '--serial', 'WD-WX12345', '--name', 'drive-four').run
      expect(manifest.drives.first).to have_attributes(serial_number: 'WD-WX12345', friendly_name: 'drive-four',
                                                       volume_uuid: 'ABCD-1234')
    end

    it 'refuses a volume that already carries a marker' do
      cli('jbod', 'register-drive', vol).run
      expect(cli('jbod', 'register-drive', vol, '--serial', 'other').run).to eq(1)
      expect(err.string).to include('already carries a marker')
      expect(manifest.drives.size).to eq(1)
    end

    it 'fails cleanly when the mount point does not exist' do
      expect(cli('jbod', 'register-drive', File.join(mount_root, 'nope')).run).to eq(1)
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
      fake_shell.on(->(argv) { argv == ['smartctl', '-a', '/dev/disk0s2'] }, output: "Serial Number: 0ba0284a20e0ec22\n")

      expect(cli('jbod', 'register-drive', vol).run).to eq(0)
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
      expect(cli('jbod', 'reassign', 'Photos', 'backup-02-6tb', '--note', 'copied by hand').run).to eq(0)
      expect(manifest.folder('Photos').drive_serial).to eq('S2')
      expect(out.string).to include('No data was moved')
      cli('jbod', 'history', 'Photos').run
      expect(out.string).to include('reassigned', 'copied by hand', 'assigned')
    end

    it 'rejects an unknown drive name' do
      expect(cli('jbod', 'reassign', 'Photos', 'backup-99').run).to eq(1)
      expect(err.string).to include('no drive named backup-99')
    end

    it 'prints status' do
      expect(cli('jbod', 'status').run).to eq(0)
      expect(out.string).to include('backup-01-3tb', 'not mounted', 'Photos')
    end
  end

  describe 'jbod sync' do
    def merge_jbod_config(**overrides)
      cfg = YAML.safe_load_file(config_path, permitted_classes: [Symbol], symbolize_names: true)
      File.write(config_path, cfg.merge(jbod: cfg[:jbod].merge(overrides)).to_yaml)
    end

    it 'refuses to run with an old rsync' do
      fake_shell.on('rsync', output: "rsync  version 2.6.9  protocol version 29\n")
      expect(cli('jbod', 'sync').run).to eq(1)
      expect(err.string).to include('too old')
    end

    it 'refuses a second concurrent run and leaves an already-running lock untouched' do
      lock_path = File.join(temp_dir, 'jbod.lock')
      merge_jbod_config(lock_path: lock_path)
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.write(lock_path, Process.pid.to_s) # simulate a live concurrent run
      fake_shell.on('rsync', output: "rsync  version 3.5.0  protocol version 32\n")

      expect(cli('jbod', 'sync').run).to eq(1)
      expect(err.string).to include('already running', "pid #{Process.pid}")
      expect(File.read(lock_path)).to eq(Process.pid.to_s)
    end

    it 'releases the lock after a run so a later sync can proceed' do
      lock_path = File.join(temp_dir, 'jbod.lock')
      merge_jbod_config(lock_path: lock_path, sources: [])
      fake_shell.on('rsync', output: "rsync  version 3.5.0  protocol version 32\n")

      cli('jbod', 'sync').run # fails fast (no sources configured), but the lock must still be released
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
      expect(cli('jbod', 'pending').run).to eq(0)
      expect(out.string).to include('2 pending', 'photos/old.jpg', 'photos (whole folder)', 'since 2026-09-01')
    end

    it 'says so when nothing is pending' do
      cli('jbod', 'pending').run
      expect(out.string).to include('Nothing is pending deletion')
    end
  end

  it 'prints usage for unknown commands' do
    expect(cli('bogus').run).to eq(1)
    expect(err.string).to include('Unknown command: bogus', 'Usage:')
  end

  it 'runs the snapshot tasks when called with no arguments' do
    expect(cli.run).to eq(0)
    expect(fake_shell.calls).to be_empty
  end
end
