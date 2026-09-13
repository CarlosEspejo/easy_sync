# frozen_string_literal: true

RSpec.describe EasySync::Jbod::Mirror do
  let(:source) { make_dirs(temp_dir, 'nas/Photos').first }

  it 'builds an archive command that reports, but never performs, deletions' do
    mirror = described_class.new(shell: fake_shell)
    expect(mirror.command('/nas/Photos', '/Volumes/backup-04-8tb/Photos'))
      .to eq(['rsync', '-a', '--stats', '--info=progress2', '--itemize-changes', '--delete', '--max-delete=0',
              '/nas/Photos/', '/Volumes/backup-04-8tb/Photos/'])
  end

  it 'appends extra arguments' do
    mirror = described_class.new(shell: fake_shell, extra_args: ['--exclude', '.DS_Store'])
    expect(mirror.command('/a/', '/b/')[-4..]).to eq(['--exclude', '.DS_Store', '/a/', '/b/'])
  end

  it 'runs rsync and parses the stats' do
    destination = File.join(temp_dir, 'Volumes', 'backup-04-8tb', 'Photos')
    fake_shell.on('rsync', output: rsync_stats(total: 123_456_789, transferred: 4_096))
    result = described_class.new(shell: fake_shell).sync(source, destination)
    expect(result).to have_attributes(exit_status: 0, total_size_bytes: 123_456_789, bytes_transferred: 4_096, extraneous: [])
    expect(result).to be_success
    expect(fake_shell.calls.last.last(2)).to eq(["#{source}/", "#{destination}/"])
  end

  it 'collects the files rsync would have deleted and treats exit 25 as success' do
    fake_shell.on('rsync', status: 25, output: <<~OUT)
      sending incremental file list
      *deleting   Old Movie (1999)/
      *deleting   Old Movie (1999)/movie.mkv
      *deleting   stray.txt
      >f+++++++++ New Movie/movie.mkv
      #{rsync_stats}
    OUT
    result = described_class.new(shell: fake_shell).sync(source, '/dest')
    expect(result).to be_success
    expect(result.extraneous).to eq([['Old Movie (1999)', 'dir'], ['Old Movie (1999)/movie.mkv', 'file'], ['stray.txt', 'file']])
  end

  it 'creates the destination parent so split-share folders land under the share directory' do
    fake_shell.on('rsync', output: rsync_stats)
    dest = File.join(temp_dir, 'Volumes', 'backup-04-8tb', 'tv', 'Show A')
    described_class.new(shell: fake_shell).sync(source, dest)
    expect(Dir).to exist(File.dirname(dest))
    expect(Dir).not_to exist(dest)
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

  it 'flags a full destination drive distinctly from other rsync failures' do
    fake_shell.on('rsync', status: 11, output: <<~OUT)
      rsync: [receiver] write failed on "/Volumes/backup-04-8tb/movies/Heat (1995)/movie.mkv": No space left on device (28)
      rsync error: error in file IO (code 11) at receiver.c(392) [receiver=3.5.0]
    OUT
    result = described_class.new(shell: fake_shell).sync(source, '/dest')
    expect(result).to be_disk_full
    expect(result).not_to be_success
  end

  it 'does not call an ordinary failure disk-full' do
    fake_shell.on('rsync', output: "rsync: connection unexpectedly closed\n", status: 12)
    result = described_class.new(shell: fake_shell).sync(source, '/dest')
    expect(result).not_to be_disk_full
  end

  describe '.check_version!' do
    it 'accepts rsync 3.x' do
      fake_shell.on('rsync', output: "rsync  version 3.5.0  protocol version 32\nCopyright (C) 1996-2026\n")
      expect(described_class.check_version!(fake_shell)).to eq('3.5.0')
    end

    it 'rejects the rsync Apple ships' do
      fake_shell.on('rsync', output: "rsync  version 2.6.9  protocol version 29\n")
      expect { described_class.check_version!(fake_shell) }.to raise_error(EasySync::Error, /2\.6\.9 is too old/)
    end

    it 'reports a missing rsync' do
      fake_shell.on('rsync', output: '', status: 127)
      expect { described_class.check_version!(fake_shell) }.to raise_error(EasySync::Error, /not found/)
    end
  end
end
