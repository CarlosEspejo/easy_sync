# frozen_string_literal: true

RSpec.describe EasySync::Jbod::RunLock do
  let(:path) { File.join(temp_dir, 'nested', 'jbod.lock') }
  let(:lock) { described_class.new(path) }

  it 'creates the lock file, runs the block, and removes it afterward' do
    ran = false
    lock.acquire do
      expect(File).to exist(path)
      expect(File.read(path)).to eq(Process.pid.to_s)
      ran = true
    end
    expect(ran).to be true
    expect(File).not_to exist(path)
  end

  it 'creates parent directories as needed' do
    lock.acquire {}
    expect(Dir).to exist(File.dirname(path))
  end

  it 'releases the lock even when the block raises' do
    expect { lock.acquire { raise 'boom' } }.to raise_error('boom')
    expect(File).not_to exist(path)
  end

  it 'refuses a second acquire while a live process holds the lock' do
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, Process.pid.to_s) # this test process is definitely alive

    expect { lock.acquire {} }.to raise_error(described_class::AlreadyRunning, /pid #{Process.pid}/)
    expect(File.read(path)).to eq(Process.pid.to_s) # untouched - not ours to delete
  end

  it 'reclaims a stale lock left by a process that is no longer running' do
    FileUtils.mkdir_p(File.dirname(path))
    dead_pid = 999_999 # exceedingly unlikely to be a live PID during a test run
    File.write(path, dead_pid.to_s)

    ran = false
    lock.acquire { ran = true }
    expect(ran).to be true
    expect(File).not_to exist(path)
  end

  it 'treats a garbage lock file as stale rather than raising' do
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, 'not-a-pid')

    ran = false
    lock.acquire { ran = true }
    expect(ran).to be true
  end

  it 'does not delete a lock file that a concurrent run has since overwritten' do
    lock.acquire do
      File.write(path, '424242') # simulate another process reclaiming after ours went stale somehow
    end
    expect(File.read(path)).to eq('424242')
  end

  describe '#status' do
    it 'is nil when no lock file exists' do
      expect(lock.status).to be_nil
    end

    it 'reports the pid and the lock file mtime as the start time while a live process holds it' do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, Process.pid.to_s)

      status = lock.status
      expect(status.pid).to eq(Process.pid)
      expect(status.started_at).to eq(File.mtime(path))
    end

    it 'is nil for a stale lock left by a process that is no longer running' do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, '999999')

      expect(lock.status).to be_nil
    end
  end
end
