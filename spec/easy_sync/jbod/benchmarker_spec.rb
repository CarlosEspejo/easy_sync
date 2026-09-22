# frozen_string_literal: true

require 'json'

RSpec.describe EasySync::Jbod::Benchmarker do
  let(:manifest) { memory_manifest }
  let(:drive) { manifest.register_drive(serial_number: 'SN1', friendly_name: 'backup-04-8tb', capacity_bytes: 8 * TB) }
  let(:drive_root) { File.join(temp_dir, 'Volumes', 'backup-04-8tb') }
  let(:mounted_drive) { mounted(drive, free: 1 * TB, mount_point: drive_root) }
  let(:test_file) { File.join(drive_root, EasySync::Jbod::DRIVE_DIR, described_class::TEST_FILE) }
  let(:size) { (2 * described_class::CHUNK_SIZE) + 12_345 } # not a whole number of chunks

  # Each call returns the next value: write starts at 0 and ends at 2, read starts at 10 and ends at 11.
  def timer(*ticks) = -> { ticks.shift }

  before do
    write_file(File.join(drive_root, EasySync::Jbod::MARKER_FILE), JSON.generate(serial_number: 'SN1'))
  end

  it 'times writing and reading back exactly +size+ bytes, then removes the test file' do
    written = nil
    allow(EasySync::Jbod::PageCache).to receive(:evict).and_wrap_original do |m, io|
      written = io.size
      m.call(io)
    end

    result = described_class.new(timer: timer(0, 2.0, 10.0, 11.0)).run(mounted_drive, size: size)
    expect(result).to be_ok
    expect(written).to eq(size)
    expect(result.write_seconds).to eq(2.0)
    expect(result.read_seconds).to eq(1.0)
    expect(result.write_mb_s).to be_within(0.001).of(size / 2.0 / (1024 * 1024))
    expect(result.read_mb_s).to be_within(0.001).of(size / 1.0 / (1024 * 1024))
    expect(result.used_bytes).to eq(mounted_drive.used_bytes)
    expect(File.exist?(test_file)).to be(false)
  end

  it 'evicts the test file from the page cache before reading it, so the read comes off the drive' do
    expect(EasySync::Jbod::PageCache).to receive(:evict).once.and_call_original
    described_class.new.run(mounted_drive, size: size)
  end

  it 'removes a test file left behind by a killed run before starting' do
    write_file(test_file, 'x' * (3 * described_class::CHUNK_SIZE))
    written = nil
    allow(EasySync::Jbod::PageCache).to receive(:evict) { |io| written = io.size }

    described_class.new.run(mounted_drive, size: 1024)
    expect(written).to eq(1024)
    expect(File.exist?(test_file)).to be(false)
  end

  it 'reports an I/O failure in the result, still removing the test file' do
    allow_any_instance_of(File).to receive(:fsync).and_raise(Errno::EIO)

    result = described_class.new.run(mounted_drive, size: size)
    expect(result).not_to be_ok
    expect(result.error).to include('Input/output error')
    expect(File.exist?(test_file)).to be(false)
  end

  it 'says the drive was unmounted when its marker is gone by the time the failure is seen' do
    allow_any_instance_of(File).to receive(:fsync) do
      File.delete(File.join(drive_root, EasySync::Jbod::MARKER_FILE))
      raise Errno::ENOENT
    end

    expect(described_class.new.run(mounted_drive, size: size).error).to eq('unmounted mid-run')
  end

  describe '.compare' do
    def run(write, read) = EasySync::Jbod::DriveBenchmark.new(write_mb_s: write, read_mb_s: read)

    it 'has nothing to compare against on a first run' do
      cmp = described_class.compare([])
      expect(cmp.earlier).to eq(0)
      expect(cmp.slower(10, 10)).to eq([])
    end

    it "compares against the median of the drive's earlier runs" do
      cmp = described_class.compare([run(200, 210), run(180, 190), run(100, 250), run(190, 200)])
      expect(cmp).to have_attributes(earlier: 4, write_median: 185.0, read_median: 205.0)
      expect(cmp.write_change(203.5)).to be_within(0.0001).of(0.1)
    end

    it 'flags a rate more than 15% below the median, and not one within normal run-to-run variation' do
      cmp = described_class.compare([run(200, 200), run(200, 200), run(200, 200)])
      expect(cmp.slower(180, 186)).to eq([])       # -10%, -7%
      expect(cmp.slower(160, 186)).to eq([:write])
      expect(cmp.slower(160, 150)).to eq(%i[write read])
    end

    it 'never flags a slowdown until there are enough earlier runs to trust the median' do
      cmp = described_class.compare([run(200, 200), run(200, 200)])
      expect(cmp).not_to be_enough
      expect(cmp.slower(50, 50)).to eq([])
    end
  end
end
