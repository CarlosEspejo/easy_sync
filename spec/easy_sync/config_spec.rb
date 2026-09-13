# frozen_string_literal: true

RSpec.describe EasySync::Config do
  let(:path) { File.join(temp_dir, 'config.yml') }

  it 'loads a flat config and exposes it as settings' do
    File.write(path, { sources: ['/Volumes/photos', { path: '/Volumes/tv', split: true }], grace_days: 9 }.to_yaml)
    config, status = described_class.load(path)
    expect(status).to be_nil
    expect(config.settings[:sources]).to eq(['/Volumes/photos', { path: '/Volumes/tv', split: true }])
    expect(config.settings[:grace_days]).to eq(9)
    expect(config.settings[:config_path]).to eq(path)
    expect(config[:grace_days]).to eq(9)
  end

  it 'still reads the 1.x layout with settings nested under :jbod: and ignores :logging:/:tasks:' do
    File.write(path, { logging: :on, tasks: [{ sync_name: 'x' }], jbod: { grace_days: 3, sources: ['/Volumes/a'] } }.to_yaml)
    s = described_class.load(path).first.settings
    expect(s[:grace_days]).to eq(3)
    expect(s[:sources]).to eq(['/Volumes/a'])
    expect(s).not_to have_key(:logging)
    expect(s).not_to have_key(:tasks)
  end

  it 'fills in defaults for missing keys' do
    File.write(path, { grace_days: 7 }.to_yaml)
    s = described_class.load(path).first.settings
    expect(s).to include(mount_root: '/Volumes', purge: true, grace_days: 7, grace_runs: 2, keep_awake: true, keep_logs: 20)
    expect(s[:reserve_bytes]).to eq(2 * 1024**3)
    File.write(path, { reserve: '500mb' }.to_yaml)
    expect(described_class.load(path).first.settings[:reserve_bytes]).to eq(500 * 1024**2)
    expect(s[:exclude_folders]).to include('#recycle', '@eaDir', '.sync', '.smbdelete*')
  end

  it 'expands ~ in every path setting, including sources' do
    File.write(path, { manifest_path: '~/.easy_sync/m.sqlite3', lock_path: '~/x.lock', log_dir: '~/logs',
                       sources: ['~/nas/photos', { path: '~/nas/tv', split: true }] }.to_yaml)
    s = described_class.load(path).first.settings
    expect(s[:manifest_path]).to eq(File.join(Dir.home, '.easy_sync/m.sqlite3'))
    expect(s[:lock_path]).to eq(File.join(Dir.home, 'x.lock'))
    expect(s[:log_dir]).to eq(File.join(Dir.home, 'logs'))
    expect(s[:sources]).to eq([File.join(Dir.home, 'nas/photos'), { path: File.join(Dir.home, 'nas/tv'), split: true }])
  end

  it 'resolves the manifest, dashboard, lock and log defaults under HOME_DIR at call time' do
    File.write(path, {}.to_yaml)
    s = described_class.load(path).first.settings
    %i[manifest_path dashboard_path lock_path log_dir].each do |k|
      expect(s[k]).to start_with(File.join(temp_dir, 'home', '.easy_sync'))
      expect(s[k]).not_to start_with(Dir.home)
    end
  end

  it 'moves a legacy ~/.easy_syncrc.yml into place the first time' do
    legacy = File.join(temp_dir, '.easy_syncrc.yml')
    File.write(legacy, { logging: :off, jbod: { grace_days: 3 } }.to_yaml)
    new_path = File.join(temp_dir, '.easy_sync', 'config.yml')
    config, status = described_class.load(new_path, legacy_path: legacy)
    expect(status).to eq(:migrated)
    expect(File).to exist(new_path)
    expect(File).not_to exist(legacy)
    expect(config.settings[:grace_days]).to eq(3)
    expect(described_class.load(new_path, legacy_path: legacy).last).to be_nil
  end

  it 'defaults to ~/.easy_sync/config.yml' do
    expect(described_class.default_path).to eq(File.join(temp_dir, 'home', '.easy_sync', 'config.yml'))
    expect(described_class.default_path).not_to start_with(Dir.home)   # the guard in spec_helper is in force
  end

  it 'writes a commented, loadable sample when the file is missing' do
    _, status = described_class.load(path)
    expect(status).to eq(:generated)
    text = File.read(path)
    expect(text).to include('# easy_sync configuration', 'easy_sync add-source', ':sources: []', ':grace_days:')
    expect(text).not_to include(':jbod:', ':tasks:', ':logging:')
    expect(described_class.load(path).first.settings[:grace_days]).to eq(7)
    expect(described_class.load(path).first.source_entries).to eq([])
  end

  it 'adds, removes and re-splits sources, and writes a commented file that loads back identically' do
    config, = described_class.load(path)
    config.add_source('/Volumes/tv', split: true)
    config.add_source('/Volumes/pro', split: false)
    config.set_split('/Volumes/pro', true)
    config.save
    text = File.read(path)
    expect(text).to include('# easy_sync configuration', ':sources:                               # NAS shares',
                            '- :path: "/Volumes/tv"', ':split: true                          # each subfolder placed on its own',
                            ':grace_days: 7                          # ...this many days')
    reloaded = described_class.load(path).first
    expect(reloaded.source_entries).to eq([{ path: '/Volumes/tv', split: true }, { path: '/Volumes/pro', split: true }])
    expect(reloaded.settings.except(:config_path)).to eq(config.settings.except(:config_path))

    reloaded.remove_source('/Volumes/tv')
    reloaded.save
    expect(described_class.load(path).first.source_entries).to eq([{ path: '/Volumes/pro', split: true }])
    expect { reloaded.remove_source('/Volumes/nope') }.to raise_error(EasySync::Error, /not a source/)
    expect { reloaded.add_source('/Volumes/pro', split: false) }.to raise_error(EasySync::Error, /already a source/)
  end

  it 'keeps keys it does not know and non-scalar values when rewriting' do
    File.write(path, { custom: 'x', exclude_folders: ['#recycle', '.DS_Store'], rsync_args: ['--bwlimit=1000'] }.to_yaml)
    config, = described_class.load(path)
    config.save
    s = described_class.load(path).first
    expect(s.data[:custom]).to eq('x')
    expect(s.settings[:exclude_folders]).to eq(['#recycle', '.DS_Store'])
    expect(s.settings[:rsync_args]).to eq(['--bwlimit=1000'])
  end
end
