# frozen_string_literal: true

RSpec.describe EasySync::Jbod::Mirror do
  let(:source) { make_dirs(temp_dir, 'nas/Photos').first }

  it 'builds an archive mirror command with --delete by default and trailing slashes' do
    mirror = described_class.new(shell: fake_shell)
    expect(mirror.command('/nas/Photos', '/Volumes/backup-04-8tb/Photos'))
      .to eq(['rsync', '-a', '--stats', '--info=progress2', '--delete', '/nas/Photos/', '/Volumes/backup-04-8tb/Photos/'])
  end

  it 'can omit --delete and append extra arguments' do
    mirror = described_class.new(shell: fake_shell, delete: false, extra_args: ['--exclude', '.DS_Store'])
    expect(mirror.command('/a/', '/b/')).to eq(['rsync', '-a', '--stats', '--info=progress2', '--exclude', '.DS_Store', '/a/', '/b/'])
  end

  it 'runs rsync and parses the stats' do
    fake_shell.on('rsync', output: rsync_stats(total: 123_456_789, transferred: 4_096))
    result = described_class.new(shell: fake_shell).sync(source, '/Volumes/backup-04-8tb/Photos')
    expect(result).to have_attributes(exit_status: 0, total_size_bytes: 123_456_789, bytes_transferred: 4_096)
    expect(result).to be_success
    expect(fake_shell.calls.last.last(2)).to eq(["#{source}/", '/Volumes/backup-04-8tb/Photos/'])
  end

  it 'reports a failing exit status with nil stats' do
    fake_shell.on('rsync', output: "rsync: connection unexpectedly closed\n", status: 12)
    result = described_class.new(shell: fake_shell).sync(source, '/dest')
    expect(result).to have_attributes(exit_status: 12, total_size_bytes: nil, bytes_transferred: nil)
    expect(result).not_to be_success
  end

  it 'refuses to run when the source folder is missing' do
    expect { described_class.new(shell: fake_shell).sync(File.join(temp_dir, 'gone'), '/dest') }
      .to raise_error(EasySync::Error, /does not exist/)
    expect(fake_shell.calls).to be_empty
  end
end
