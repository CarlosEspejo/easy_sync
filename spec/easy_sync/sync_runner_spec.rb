# frozen_string_literal: true

RSpec.describe EasySync::SyncRunner do
  let(:config_path) { File.join(temp_dir, '.easy_syncrc.yml') }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  def write_config(data)
    File.write(config_path, data.to_yaml)
  end

  it 'generates a sample config when none exists' do
    described_class.new(config_path: config_path, shell: fake_shell, out: out, err: err)
    expect(YAML.safe_load_file(config_path, permitted_classes: [Symbol], symbolize_names: true))
      .to eq(EasySync::Config.sample)
    expect(err.string).to include("Generated sample config file: #{config_path}")
  end

  it 'reads the logging setting' do
    write_config(logging: :off, tasks: [])
    expect(described_class.new(config_path: config_path, shell: fake_shell, out: out, err: err).config.logging).to eq(:off)
  end

  it 'runs every task, applying the global logging setting' do
    fake_shell.on('rsync')
    write_config(logging: :on, tasks: [
                   { sync_name: 'one', source: '/a/', destination: File.join(temp_dir, 'a'), exclude_file: '' },
                   { sync_name: 'two', source: '/b/', destination: File.join(temp_dir, 'b'), exclude_file: '' }
                 ])
    described_class.new(config_path: config_path, shell: fake_shell, out: out, err: err).run
    calls = fake_shell.calls_to('rsync')
    expect(calls.size).to eq(2)
    expect(calls).to all(include('--log-file'))
    expect(calls.map { |c| c[-2] }).to eq(['/a/', '/b/'])
  end
end
