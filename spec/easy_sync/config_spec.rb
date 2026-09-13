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
    expect(text).to include('# easy_sync configuration', ':sources:', ':split:', ':grace_days:')
    expect(text).not_to include(':jbod:', ':tasks:', ':logging:')
    expect(described_class.load(path).first.settings[:grace_days]).to eq(7)
  end
end
