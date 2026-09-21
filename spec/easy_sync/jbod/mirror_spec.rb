# frozen_string_literal: true

RSpec.describe EasySync::Jbod::Mirror do
  let(:source) { make_dirs(temp_dir, 'nas/Photos').first }

  it 'builds a copy command with no deletion flags, and a separate read-only deletion probe' do
    mirror = described_class.new(shell: fake_shell)
    expect(mirror.command('/nas/Photos', '/Volumes/backup-04-8tb/Photos'))
      .to eq(['rsync', '-a', '--partial', '--stats', '--info=progress2', '--itemize-changes',
              '/nas/Photos/', '/Volumes/backup-04-8tb/Photos/'])
    expect(mirror.probe_command('/nas/Photos', '/Volumes/backup-04-8tb/Photos'))
      .to eq(['rsync', '-an', '--itemize-changes', '--delete', '--delete-excluded', '/nas/Photos/', '/Volumes/backup-04-8tb/Photos/'])
  end

  it 'passes exclusions to both passes, and asks the probe to report already-copied excluded junk' do
    mirror = described_class.new(shell: fake_shell, excludes: ['#recycle', '.smbdelete*'])
    expect(mirror.command('/a', '/b')).to include('--exclude=#recycle', '--exclude=.smbdelete*')
    expect(mirror.probe_command('/a', '/b')).to include('--delete-excluded', '--exclude=#recycle', '--exclude=.smbdelete*')
    expect(mirror.probe_command('/a', '/b').last(2)).to eq(['/a/', '/b/'])
  end

  it 'appends extra arguments' do
    mirror = described_class.new(shell: fake_shell, extra_args: ['--exclude', '.DS_Store'])
    expect(mirror.command('/a/', '/b/')[-4..]).to eq(['--exclude', '.DS_Store', '/a/', '/b/'])
  end

  it 'runs the copy pass, then the probe, and parses the stats' do
    destination = File.join(temp_dir, 'Volumes', 'backup-04-8tb', 'Photos')
    fake_shell.on('rsync', output: rsync_stats(total: 123_456_789, transferred: 4_096))
    fake_shell.on(->(argv) { argv[1] == '-an' }, output: '')
    result = described_class.new(shell: fake_shell).sync(source, destination)
    expect(result).to have_attributes(exit_status: 0, total_size_bytes: 123_456_789, bytes_transferred: 4_096, extraneous: [])
    expect(result).to be_success
    expect(fake_shell.calls_to('rsync').map { |c| c[1] }).to eq(['-a', '-an'])
    expect(fake_shell.calls.last.last(2)).to eq(["#{source}/", "#{destination}/"])
  end

  it 'collects what the probe would delete (real rsync 3.5 dry-run output)' do
    fake_shell.on('rsync', output: rsync_stats)
    fake_shell.on(->(argv) { argv[1] == '-an' }, output: <<~OUT)
      *deleting   Old Movie (1999)/
      *deleting   Old Movie (1999)/movie.mkv
      *deleting   ep2.mkv
    OUT
    result = described_class.new(shell: fake_shell).sync(source, '/dest')
    expect(result).to be_success
    expect(result.extraneous).to eq([['Old Movie (1999)', 'dir'], ['Old Movie (1999)/movie.mkv', 'file'], ['ep2.mkv', 'file']])
  end

  it 'skips the probe after a failed copy, and reports nil if the probe itself fails' do
    fake_shell.on('rsync', output: 'boom', status: 23)
    result = described_class.new(shell: fake_shell).sync(source, '/dest')
    expect(result.extraneous).to be_nil
    expect(fake_shell.calls_to('rsync').size).to eq(1)

    fake_shell.on('rsync', output: rsync_stats)
    fake_shell.on(->(argv) { argv[1] == '-an' }, output: 'rsync: link_stat failed', status: 23)
    expect(described_class.new(shell: fake_shell).sync(source, '/dest').extraneous).to be_nil
  end

  it 'creates the destination parent so split-share folders land under the share directory' do
    fake_shell.on('rsync', output: rsync_stats)
    fake_shell.on(->(argv) { argv[1] == '-an' }, output: '')
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

  describe '#refetch' do
    it 'runs rsync -I with a NUL-separated --files-from list, and no --partial' do
      captured = nil
      fake_shell.on('rsync', output: lambda { |argv|
        list_arg = argv.find { |a| a.start_with?('--files-from=') }
        captured = File.read(list_arg.delete_prefix('--files-from='))
        rsync_stats
      })
      result = described_class.new(shell: fake_shell).refetch('/nas/movies/Heat (1995)', '/Volumes/backup-04-8tb/movies/Heat (1995)',
                                                               ['movie.mkv', 'subs/en.srt'])
      expect(result).to be_success
      expect(captured).to eq("movie.mkv\x00subs/en.srt")

      call = fake_shell.calls.last
      expect(call[0, 4]).to eq(['rsync', '-a', '-I', '--stats'])
      expect(call).to include('--from0')
      expect(call).not_to include('--partial')
      expect(call.last(2)).to eq(['/nas/movies/Heat (1995)/', '/Volumes/backup-04-8tb/movies/Heat (1995)/'])
    end

    it 'cleans up its temp file after the call' do
      list_path = nil
      fake_shell.on('rsync', output: lambda { |argv|
        list_path = argv.find { |a| a.start_with?('--files-from=') }.delete_prefix('--files-from=')
        rsync_stats
      })
      described_class.new(shell: fake_shell).refetch('/a', '/b', ['x'])
      expect(File).not_to exist(list_path)
    end
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
