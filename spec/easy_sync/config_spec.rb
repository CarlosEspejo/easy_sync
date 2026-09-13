# frozen_string_literal: true

RSpec.describe EasySync::Config do
  let(:path) { File.join(temp_dir, 'rc.yml') }

  it 'loads symbol keys and values on modern Psych' do
    File.write(path, { logging: :on, tasks: [], jbod: { sources: ['/Volumes/photos', { path: '/Volumes/tv', split: true }], warn_threshold: 0.9 } }.to_yaml)
    config, generated = described_class.load(path)
    expect(generated).to be(false)
    expect(config.logging).to eq(:on)
    expect(config.jbod[:sources]).to eq(['/Volumes/photos', { path: '/Volumes/tv', split: true }])
    expect(config.jbod[:warn_threshold]).to eq(0.9)
  end

  it 'fills in jbod defaults for missing keys' do
    File.write(path, { logging: :off }.to_yaml)
    config, = described_class.load(path)
    expect(config.jbod).to include(mount_root: '/Volumes', delete: true, warn_threshold: 0.85)
    expect(config.jbod[:exclude_folders]).to include('#recycle', '@eaDir')
  end

  it 'writes a sample file with both sections when missing' do
    _, generated = described_class.load(path)
    expect(generated).to be(true)
    expect(File.read(path)).to include(':jbod:', ':tasks:', ':sources:', ':split:')
  end
end
