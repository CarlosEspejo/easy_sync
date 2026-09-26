# frozen_string_literal: true

RSpec.describe EasySync::Jbod::Mirror do
  let(:source) { make_dirs(temp_dir, 'nas/Photos').first }

  it 'builds a copy command with no deletion flags, and a separate read-only check probe' do
    mirror = described_class.new(shell: fake_shell)
    expect(mirror.command('/nas/Photos', '/Volumes/backup-04-8tb/Photos'))
      .to eq(['rsync', '-a', '--partial', '--stats', '--info=progress2', '--itemize-changes',
              '/nas/Photos/', '/Volumes/backup-04-8tb/Photos/'])
    expect(mirror.probe_command('/nas/Photos', '/Volumes/backup-04-8tb/Photos'))
      .to eq(['rsync', '-an', '--itemize-changes', '--stats', '--delete', '--delete-excluded', '/nas/Photos/',
              '/Volumes/backup-04-8tb/Photos/'])
  end

  it 'passes exclusions to both passes, and asks the probe to report already-copied excluded junk' do
    mirror = described_class.new(shell: fake_shell, excludes: ['#recycle', '.smbdelete*'])
    expect(mirror.command('/a', '/b')).to include('--exclude=#recycle', '--exclude=.smbdelete*')
    expect(mirror.probe_command('/a', '/b')).to include('--delete-excluded', '--exclude=#recycle', '--exclude=.smbdelete*')
    expect(mirror.probe_command('/a', '/b').last(2)).to eq(['/a/', '/b/'])
  end

  # Checked against real rsync 3.5.0: the copy moves only top-level files,
  # and the probe never lists the share's subfolders, even ones gone from the
  # source, because they are excluded and --delete-excluded is off.
  it 'copies only top-level files for a root-files unit, and never probes its subfolders' do
    mirror = described_class.new(shell: fake_shell, excludes: ['.DS_Store'])
    expect(mirror.command('/nas/synology', '/Volumes/b/synology', root_only: true)).to include('--exclude=/*/')
    probe = mirror.probe_command('/nas/synology', '/Volumes/b/synology', root_only: true)
    expect(probe).to include('--delete', '--exclude=/*/', '--exclude=.DS_Store')
    expect(probe).not_to include('--delete-excluded')
    expect(mirror.command('/a', '/b')).not_to include('--exclude=/*/')
  end

  it 'passes root_only through to the check and the copy' do
    source = File.join(temp_dir, 'share').tap { |d| FileUtils.mkdir_p(d) }
    fake_shell.on('rsync', output: rsync_stats)
    mirror = described_class.new(shell: fake_shell)
    mirror.check(source, File.join(temp_dir, 'drive', 'share'), root_only: true)
    mirror.sync(source, File.join(temp_dir, 'drive', 'share'), root_only: true)
    expect(fake_shell.calls_to('rsync').map { |c| c.include?('--exclude=/*/') }).to eq([true, true])
  end

  it 'appends extra arguments' do
    mirror = described_class.new(shell: fake_shell, extra_args: ['--exclude', '.DS_Store'])
    expect(mirror.command('/a/', '/b/')[-4..]).to eq(['--exclude', '.DS_Store', '/a/', '/b/'])
  end

  it 'runs only the copy pass and parses the stats' do
    destination = File.join(temp_dir, 'Volumes', 'backup-04-8tb', 'Photos')
    fake_shell.on('rsync', output: rsync_stats(total: 123_456_789, transferred: 4_096))
    result = described_class.new(shell: fake_shell).sync(source, destination)
    expect(result).to have_attributes(exit_status: 0, total_size_bytes: 123_456_789, bytes_transferred: 4_096)
    expect(result).to be_success
    expect(fake_shell.calls_to('rsync').map { |c| c[1] }).to eq(['-a'])
    expect(fake_shell.calls.last.last(2)).to eq(["#{source}/", "#{destination}/"])
  end

  # Real rsync 3.5.0 output, from a scratch tree: `a` rewritten, `new` added,
  # `sub/b` renamed to `sub/b.locked` (ransomware-style), and .DS_Store junk
  # on the drive that exclude_folders now excludes.
  let(:check_output) do
    <<~OUT
      *deleting   .DS_Store
      .d..t...... ./
      >f.st...... a
      >f+++++++++ new
      *deleting   sub/b
      *deleting   sub/.DS_Store
      >f+++++++++ sub/b.locked
      .f...p..... perms-only
      cL+++++++++ link -> a

      Number of files: 1,236 (reg: 1,003, dir: 233)
      Number of created files: 2 (reg: 2)
      Number of deleted files: 3 (reg: 3)
      Total file size: 19 bytes
    OUT
  end

  it 'checks what the copy would overwrite and what is gone from the source, before copying' do
    fake_shell.on('rsync', output: check_output)
    check = described_class.new(shell: fake_shell, excludes: ['.DS_Store']).check(source, '/dest')
    expect(check.replaced).to eq(['a'])
    expect(check.missing).to eq([['.DS_Store', 'file'], ['sub/b', 'file'], ['sub/.DS_Store', 'file']])
    expect(check.junk).to eq(['.DS_Store', 'sub/.DS_Store'])
    expect(check.missing_files).to eq(['sub/b'])
    expect(check.changed).to eq(2)
    expect(check.files_on_drive).to eq(1_003 - 2 + 3)
    expect(check.samples).to eq(['a', 'sub/b'])
    expect(fake_shell.calls_to('rsync').first).to include('-an', '--stats', '--delete')
  end

  it 'collects what the probe would delete (real rsync 3.5 dry-run output)' do
    fake_shell.on('rsync', output: <<~OUT)
      *deleting   Old Movie (1999)/
      *deleting   Old Movie (1999)/movie.mkv
      *deleting   ep2.mkv
    OUT
    check = described_class.new(shell: fake_shell).check(source, '/dest')
    expect(check.missing).to eq([['Old Movie (1999)', 'dir'], ['Old Movie (1999)/movie.mkv', 'file'], ['ep2.mkv', 'file']])
    expect(check.missing_files).to eq(['Old Movie (1999)/movie.mkv', 'ep2.mkv'])
    expect(check.source_files).to eq(0)
  end

  it 'returns nil when the check probe fails' do
    fake_shell.on('rsync', output: 'rsync: link_stat failed', status: 23)
    expect(described_class.new(shell: fake_shell).check(source, '/dest')).to be_nil
  end

  it 'creates the destination parent so each folder lands under its share directory' do
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
      rsync: [receiver] write failed on "/Volumes/backup-04-8tb/movies/Metropolis (1927)/movie.mkv": No space left on device (28)
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
      result = described_class.new(shell: fake_shell).refetch('/nas/movies/Metropolis (1927)', '/Volumes/backup-04-8tb/movies/Metropolis (1927)',
                                                               ['movie.mkv', 'subs/en.srt'])
      expect(result).to be_success
      expect(captured).to eq("movie.mkv\x00subs/en.srt")

      call = fake_shell.calls.last
      expect(call[0, 4]).to eq(['rsync', '-a', '-I', '--stats'])
      expect(call).to include('--from0')
      expect(call).not_to include('--partial')
      expect(call.last(2)).to eq(['/nas/movies/Metropolis (1927)/', '/Volumes/backup-04-8tb/movies/Metropolis (1927)/'])
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
