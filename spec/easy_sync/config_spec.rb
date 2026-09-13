# frozen_string_literal: true

RSpec.describe EasySync::Config do
  let(:path) { File.join(temp_dir, 'rc.yml') }

  it 'loads symbol keys and values on modern Psych' do
    File.write(path, { logging: :on, tasks: [], jbod: { sources: ['/Volumes/photos', { path: '/Volumes/tv', split: true }], grace_days: 9 } }.to_yaml)
    config, status = described_class.load(path)
    expect(status).to be_nil
    expect(config.jbod[:config_path]).to eq(path)
    expect(config.logging).to eq(:on)
    expect(config.jbod[:sources]).to eq(['/Volumes/photos', { path: '/Volumes/tv', split: true }])
    expect(config.jbod[:grace_days]).to eq(9)
  end

  it 'fills in jbod defaults for missing keys' do
    File.write(path, { logging: :off }.to_yaml)
    config, = described_class.load(path)
    expect(config.jbod).to include(mount_root: '/Volumes', purge: true, grace_days: 7, grace_runs: 2, keep_awake: true)
    expect(config.jbod[:exclude_folders]).to include('#recycle', '@eaDir')
  end

  it 'expands ~ in every path setting, including sources' do
    File.write(path, { jbod: { manifest_path: '~/.easy_sync/m.sqlite3', lock_path: '~/x.lock',
                               sources: ['~/nas/photos', { path: '~/nas/tv', split: true }] } }.to_yaml)
    j = described_class.load(path).first.jbod
    expect(j[:manifest_path]).to eq(File.join(Dir.home, '.easy_sync/m.sqlite3'))
    expect(j[:lock_path]).to eq(File.join(Dir.home, 'x.lock'))
    expect(j[:sources]).to eq([File.join(Dir.home, 'nas/photos'), { path: File.join(Dir.home, 'nas/tv'), split: true }])
  end

  it 'moves a legacy ~/.easy_syncrc.yml into place the first time' do
    legacy = File.join(temp_dir, '.easy_syncrc.yml')
    File.write(legacy, { logging: :off, jbod: { grace_days: 3 } }.to_yaml)
    new_path = File.join(temp_dir, '.easy_sync', 'config.yml')
    config, status = described_class.load(new_path, legacy_path: legacy)
    expect(status).to eq(:migrated)
    expect(File).to exist(new_path)
    expect(File).not_to exist(legacy)
    expect(config.jbod[:grace_days]).to eq(3)
    expect(described_class.load(new_path, legacy_path: legacy).last).to be_nil
  end

  it 'defaults to ~/.easy_sync/config.yml' do
    expect(described_class.default_path).to eq(File.join(temp_dir, 'home', '.easy_sync', 'config.yml'))
    expect(described_class.default_path).not_to start_with(Dir.home)   # the guard in spec_helper is in force
  end

  it 'writes a sample file with both sections when missing' do
    _, status = described_class.load(path)
    expect(status).to eq(:generated)
    expect(File.read(path)).to include(':jbod:', ':tasks:', ':sources:', ':split:')
  end
end
