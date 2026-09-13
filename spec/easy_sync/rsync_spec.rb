# frozen_string_literal: true

RSpec.describe EasySync::Rsync do
  let(:source) { make_dirs(temp_dir, 'source').first }
  let(:destination) { make_dirs(temp_dir, 'backup').first }
  let(:clock) { double('clock', now: Time.utc(2026, 9, 13)) }
  let(:out) { StringIO.new }
  let(:task) { { sync_name: 'test_sync', source: source, destination: destination, exclude_file: '' } }
  let(:rsync) { described_class.new(task, shell: fake_shell, out: out, clock: clock) }

  before do
    %w[2013-12-30 2013-11-10 2013-10-10 2013-11-07].each { |d| FileUtils.mkdir_p(File.join(destination, d)) }
    write_file(File.join(destination, 'exclude.txt'), "file4.txt\n")
    fake_shell.on('rsync', output: "sending incremental file list\n")
  end

  it 'finds the latest dated snapshot, ignoring other entries' do
    expect(rsync.latest_snapshot).to eq(File.join(destination, '2013-12-30'))
  end

  it 'names the new snapshot after today' do
    expect(rsync.current_snapshot).to eq(File.join(destination, '2026-09-13'))
  end

  it 'has no latest snapshot on a first run' do
    FileUtils.rm_rf(destination)
    expect(rsync.latest_snapshot).to be_nil
    expect(rsync.command).not_to include('--link-dest')
  end

  it 'builds the rsync command with link-dest and without empty options' do
    expect(rsync.command).to eq(['rsync', '-avhiPH', '--link-dest', File.join(destination, '2013-12-30'),
                                 source, File.join(destination, '2026-09-13')])
  end

  it 'adds the exclude file and log file when configured' do
    task.merge!(exclude_file: File.join(destination, 'exclude.txt'), logging: :on)
    expect(rsync.command).to include('--exclude-from', File.join(destination, 'exclude.txt'),
                                     '--log-file', File.join(Dir.home, 'easy_sync.log'))
  end

  it 'runs rsync via the shell' do
    rsync.sync
    expect(fake_shell.calls_to('rsync').size).to eq(1)
    expect(out.string).to include('Running test_sync', "latest snapshot #{File.join(destination, '2013-12-30')}")
  end

  it 'prunes only dated snapshots beyond the last five, and only after a successful sync' do
    FileUtils.mkdir_p(File.join(destination, '2014-01-01'))
    FileUtils.mkdir_p(File.join(destination, '2014-02-01'))
    rsync.sync
    remaining = Dir.children(destination).sort
    expect(remaining).to eq(%w[2013-11-07 2013-11-10 2013-12-30 2014-01-01 2014-02-01 exclude.txt])
  end

  it 'raises and does not prune when rsync fails' do
    FileUtils.mkdir_p(File.join(destination, '2014-01-01'))
    FileUtils.mkdir_p(File.join(destination, '2014-02-01'))
    fake_shell.on('rsync', output: 'boom', status: 23)
    expect { rsync.sync }.to raise_error(EasySync::Error, /status 23/)
    expect(Dir.children(destination).size).to eq(7)
  end
end
