# frozen_string_literal: true

RSpec.describe EasySync::Jbod::Placement do
  let(:manifest) { memory_manifest }
  let(:drives) { register_fleet(manifest).to_h { |d| [d.friendly_name, d] } }

  it 'picks the mounted drive with the most free space' do
    candidates = [
      mounted(drives['backup-01-3tb'], free: 1 * TB),
      mounted(drives['backup-04-8tb'], free: 5 * TB),
      mounted(drives['backup-02-6tb'], free: 4 * TB)
    ]
    expect(described_class.choose(candidates, size_bytes: 100).friendly_name).to eq('backup-04-8tb')
  end

  it 'ignores capacity and looks only at free space' do
    candidates = [
      mounted(drives['backup-07-8tb'], free: 100),
      mounted(drives['backup-01-3tb'], free: 2 * TB)
    ]
    expect(described_class.choose(candidates, size_bytes: 50).friendly_name).to eq('backup-01-3tb')
  end

  it 'breaks a tie deterministically by name' do
    candidates = [
      mounted(drives['backup-06-8tb'], free: 3 * TB),
      mounted(drives['backup-05-8tb'], free: 3 * TB)
    ]
    expect(described_class.choose(candidates).friendly_name).to eq('backup-06-8tb')
  end

  it 'raises when nothing is mounted' do
    expect { described_class.choose([], size_bytes: 1) }.to raise_error(described_class::NoMountedDrives)
  end

  it 'refuses a folder that does not fit on the emptiest drive' do
    candidates = [mounted(drives['backup-01-3tb'], free: 10)]
    expect { described_class.choose(candidates, size_bytes: 11) }
      .to raise_error(described_class::DoesNotFit, /does not fit on backup-01-3tb/)
  end

  it 'honours a reserve' do
    candidates = [mounted(drives['backup-01-3tb'], free: 100)]
    expect(described_class.choose(candidates, size_bytes: 90).friendly_name).to eq('backup-01-3tb')
    expect { described_class.choose(candidates, size_bytes: 90, reserve_bytes: 20) }
      .to raise_error(described_class::DoesNotFit)
  end

  it 'places without a size when the size is unknown' do
    candidates = [mounted(drives['backup-01-3tb'], free: 0)]
    expect(described_class.choose(candidates, size_bytes: nil).friendly_name).to eq('backup-01-3tb')
  end

  describe '.format_bytes' do
    it 'formats sizes for humans' do
      expect(described_class.format_bytes(nil)).to eq('—')
      expect(described_class.format_bytes(512)).to eq('512 B')
      expect(described_class.format_bytes(1536)).to eq('1.5 KB')
      expect(described_class.format_bytes(8 * TB)).to eq('8.0 TB')
    end
  end
end
