# frozen_string_literal: true

RSpec.describe EasySync::Jbod::RunLock do
  let(:path) { File.join(temp_dir, 'nested', 'jbod.lock') }
  let(:lock) { described_class.new(path) }

  it 'creates the lock file, runs the block, and removes it afterward' do
    ran = false
    lock.acquire do
      expect(File).to exist(path)
      expect(File.read(path).lines.map(&:strip)).to eq([Process.pid.to_s, 'sync'])
      ran = true
    end
    expect(ran).to be true
    expect(File).not_to exist(path)
  end

  it 'records which command holds the lock' do
    lock.acquire(kind: 'scrub') { expect(File.read(path).lines.map(&:strip)).to eq([Process.pid.to_s, 'scrub']) }
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

  describe '#note' do
    it 'updates the lines from the third on without releasing the lock or touching the start time' do
      lock.acquire(kind: 'scrub') do
        mtime_before = File.mtime(path)
        lock.note('backup-08-2tb')

        expect(File.read(path).lines.map(&:strip)).to eq([Process.pid.to_s, 'scrub', 'backup-08-2tb'])
        expect(File.mtime(path)).to eq(mtime_before)
        expect(lock.status.current).to eq(['backup-08-2tb'])

        lock.note('backup-01-8tb')
        expect(lock.status.current).to eq(['backup-01-8tb'])
      end
    end

    it 'writes one line per name, and reports them all as current' do
      lock.acquire(kind: 'scrub') do
        lock.note('backup-01-8tb', 'backup-03-8tb')

        expect(File.read(path).lines.map(&:strip)).to eq([Process.pid.to_s, 'scrub', 'backup-01-8tb', 'backup-03-8tb'])
        expect(lock.status.current).to eq(['backup-01-8tb', 'backup-03-8tb'])
      end
    end

    it 'clears the active set back to empty when called with no names' do
      lock.acquire(kind: 'scrub') do
        lock.note('backup-08-2tb')
        lock.note
        expect(lock.status.current).to eq([])
      end
    end

    it 'is a no-op when this process does not hold the lock' do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "999999\nscrub\n") # some other (dead) process's lock

      lock.note('backup-08-2tb')
      expect(File.read(path)).to eq("999999\nscrub\n")
    end

    it 'is a no-op when there is no lock file' do
      expect { lock.note('backup-08-2tb') }.not_to raise_error
    end
  end

  describe '#status' do
    it 'is nil when no lock file exists' do
      expect(lock.status).to be_nil
    end

    it 'has an empty current until #note has been called' do
      lock.acquire(kind: 'scrub') { expect(lock.status.current).to eq([]) }
    end

    it 'reports the pid and the lock file mtime as the start time while a live process holds it' do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, Process.pid.to_s)

      status = lock.status
      expect(status.pid).to eq(Process.pid)
      expect(status.started_at).to eq(File.mtime(path))
    end

    it "defaults to kind 'sync' for a lock file with no second line (written before scrub existed)" do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, Process.pid.to_s)

      expect(lock.status.kind).to eq('sync')
    end

    it 'reports the kind the run was acquired with' do
      lock.acquire(kind: 'scrub') { expect(lock.status.kind).to eq('scrub') }
    end

    it 'is nil for a stale lock left by a process that is no longer running' do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, '999999')

      expect(lock.status).to be_nil
    end
  end
end
