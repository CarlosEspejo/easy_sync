# frozen_string_literal: true

RSpec.describe EasySync::Config do
  let(:path) { File.join(temp_dir, 'rc.yml') }

  it 'loads symbol keys and values on modern Psych' do
    File.write(path, { logging: :on, tasks: [], jbod: { sources: ['/Volumes/photos', { path: '/Volumes/tv', split: true }], grace_days: 9 } }.to_yaml)
    config, generated = described_class.load(path)
    expect(generated).to be(false)
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

  it 'writes a sample file with both sections when missing' do
    _, generated = described_class.load(path)
    expect(generated).to be(true)
    expect(File.read(path)).to include(':jbod:', ':tasks:', ':sources:', ':split:')
  end
end
