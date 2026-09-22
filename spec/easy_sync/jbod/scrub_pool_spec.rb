# frozen_string_literal: true

require 'json'

RSpec.describe EasySync::Jbod::ScrubPool do
  let(:manifest_path) { File.join(temp_dir, 'manifest.sqlite3') }
  let(:mount_root) { File.join(temp_dir, 'Volumes') }
  let(:lock_path) { File.join(temp_dir, 'jbod.lock') }
  let(:lock) { EasySync::Jbod::RunLock.new(lock_path) }
  let(:out) { StringIO.new }

  def open_manifest = EasySync::Jbod::Manifest.open(manifest_path)

  # A file-backed drive with one small tracked file, mirroring
  # spec/support/manifest_helpers.rb's #mounted for a real, on-disk drive
  # (Jbod::ScrubPool's workers need a real file per connection, not :memory:).
  def make_drive(name, serial)
    vol = make_dirs(mount_root, name).first
    write_file(File.join(vol, EasySync::Jbod::MARKER_FILE), JSON.generate(serial_number: serial, friendly_name: name))
    folder = "data-#{name}"
    write_file(File.join(vol, folder, 'f0.bin'), 'sample content')
    m = open_manifest
    drive = m.register_drive(serial_number: serial, friendly_name: name, capacity_bytes: 3 * TB)
    m.assign_folder(folder, serial)
    m.close
    EasySync::Jbod::MountedDrive.new(drive: drive, mount_point: vol, capacity_bytes: drive.capacity_bytes,
                                     used_bytes: 0, free_bytes: drive.capacity_bytes)
  end

  def pool(jobs:, deadline: nil, clock: Time)
    described_class.new(jobs: jobs, open_manifest: -> { open_manifest }, lock: lock,
                        scrubber_options: { excludes: [] }, clock: clock, deadline: deadline, out: out)
  end

  around { |example| lock.acquire(kind: 'scrub') { example.run } }

  it 'baselines every file across all drives and returns results in target order' do
    targets = [make_drive('backup-01', 'S1'), make_drive('backup-02', 'S2'), make_drive('backup-03', 'S3')]

    results = pool(jobs: 2).run(targets)

    expect(results.map(&:drive)).to eq(%w[backup-01 backup-02 backup-03])
    expect(results.map(&:baselined)).to eq([1, 1, 1])
    m = open_manifest
    expect(m.checksum_rows('S1', 'data-backup-01').first.digest).to be_a(String)
    expect(m.checksum_rows('S2', 'data-backup-02').first.digest).to be_a(String)
    expect(m.checksum_rows('S3', 'data-backup-03').first.digest).to be_a(String)
  end

  it 'runs at most `jobs` drives at once, never two workers on the same drive, and reports the active set to the lock' do
    targets = [make_drive('backup-01', 'S1'), make_drive('backup-02', 'S2'), make_drive('backup-03', 'S3')]
    active_mutex = Mutex.new
    in_flight = 0
    max_in_flight = 0
    per_drive = Hash.new(0)
    per_drive_max = Hash.new(0)
    noted = []
    allow(lock).to receive(:note).and_wrap_original do |m, *names|
      noted << names
      m.call(*names)
    end
    allow_any_instance_of(EasySync::Jbod::Scrubber).to receive(:run).and_wrap_original do |m, target|
      active_mutex.synchronize do
        in_flight += 1
        max_in_flight = [max_in_flight, in_flight].max
        per_drive[target.friendly_name] += 1
        per_drive_max[target.friendly_name] = [per_drive_max[target.friendly_name], per_drive[target.friendly_name]].max
      end
      sleep 0.05 # widen the overlap window so concurrent workers are actually caught
      result = m.call(target)
      active_mutex.synchronize { in_flight -= 1; per_drive[target.friendly_name] -= 1 }
      result
    end

    pool(jobs: 2).run(targets)

    expect(max_in_flight).to be <= 2
    expect(per_drive_max.values).to all(eq(1))          # never two workers on the same drive at once
    expect(noted.any? { |n| n.size == 2 }).to be true   # at some point two drives were active together
    expect(noted.last).to eq([])                        # nothing left active once the run finishes
  end

  it 'does not start a new drive once the shared deadline has passed' do
    targets = [make_drive('backup-01', 'S1'), make_drive('backup-02', 'S2'), make_drive('backup-03', 'S3')]
    base = Time.utc(2026, 9, 21, 12, 0, 0)
    clock = Object.new
    clock.define_singleton_method(:now) { @now ||= base }
    clock.define_singleton_method(:now=) { |v| @now = v }
    deadline = base + 100

    allow_any_instance_of(EasySync::Jbod::Scrubber).to receive(:run).and_wrap_original do |m, target|
      result = m.call(target)
      clock.now = base + 1000 if target.friendly_name == 'backup-01' # past the deadline from here on
      result
    end

    results = pool(jobs: 1, deadline: deadline, clock: clock).run(targets)

    expect(results.size).to eq(1)
    expect(results.first.drive).to eq('backup-01')
    m = open_manifest
    expect(m.checksum_rows('S2', 'data-backup-02')).to be_empty
    expect(m.checksum_rows('S3', 'data-backup-03')).to be_empty
  end

  it 'stops every worker on Interrupt raised in the calling thread, re-raises it, and keeps completed drives baselined' do
    targets = [make_drive('backup-01', 'S1'), make_drive('backup-02', 'S2'), make_drive('backup-03', 'S3')]
    allow_any_instance_of(EasySync::Jbod::Scrubber).to receive(:run).and_wrap_original do |m, target|
      target.friendly_name == 'backup-03' ? sleep(5) : m.call(target)
    end
    calling_thread = Thread.current
    interrupter = Thread.new { sleep 0.2; calling_thread.raise(Interrupt) }

    expect { pool(jobs: 3).run(targets) }.to raise_error(Interrupt)
    interrupter.join

    m = open_manifest
    expect(m.checksum_rows('S1', 'data-backup-01')).not_to be_empty
    expect(m.checksum_rows('S2', 'data-backup-02')).not_to be_empty
    expect(m.checksum_rows('S3', 'data-backup-03')).to be_empty
  end

  it 'propagates an exception raised inside one worker, and still flushes what the others completed' do
    targets = [make_drive('backup-01', 'S1'), make_drive('backup-02', 'S2'), make_drive('backup-03', 'S3')]
    allow_any_instance_of(EasySync::Jbod::Scrubber).to receive(:run).and_wrap_original do |m, target|
      raise 'boom' if target.friendly_name == 'backup-02'

      m.call(target)
    end

    expect { pool(jobs: 3).run(targets) }.to raise_error('boom')

    m = open_manifest
    expect(m.checksum_rows('S1', 'data-backup-01')).not_to be_empty
    expect(m.checksum_rows('S3', 'data-backup-03')).not_to be_empty
  end

  it 'returns an empty array for no targets' do
    expect(pool(jobs: 4).run([])).to eq([])
  end
end
