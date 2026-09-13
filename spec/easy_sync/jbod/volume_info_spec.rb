# frozen_string_literal: true

RSpec.describe EasySync::Jbod::VolumeInfo do
  let(:mount_root) { File.join(temp_dir, 'Volumes') }
  let(:info) { described_class.new(mount_root: mount_root, shell: fake_shell) }
  let(:manifest) { memory_manifest }
  let(:drives) { register_fleet(manifest).to_h { |d| [d.friendly_name, d] } }

  before { FileUtils.mkdir_p(mount_root) }

  def df_for(mount, capacity_kb, used_kb)
    fake_shell.on(->(argv) { argv[0] == 'df' && argv.last == mount },
                  output: df_output(mount, capacity_kb: capacity_kb, used_kb: used_kb))
  end

  describe '#write_marker / #read_marker' do
    it 'round-trips the identity file at the volume root' do
      vol = make_dirs(mount_root, 'backup-04-8tb').first
      info.write_marker(vol, serial_number: 'SN-4', friendly_name: 'backup-04-8tb', registered_at: 'now')
      expect(File).to exist(File.join(vol, EasySync::Jbod::MARKER_FILE))
      expect(info.read_marker(vol)).to eq(serial_number: 'SN-4', friendly_name: 'backup-04-8tb', registered_at: 'now')
    end

    it 'returns nil for missing or corrupt markers' do
      vol = make_dirs(mount_root, 'x').first
      expect(info.read_marker(vol)).to be_nil
      write_file(File.join(vol, EasySync::Jbod::MARKER_FILE), '{not json')
      expect(info.read_marker(vol)).to be_nil
    end

    it 'refuses to write a marker to a path that is not mounted' do
      expect { info.write_marker(File.join(mount_root, 'gone'), serial_number: 'x', friendly_name: 'y') }
        .to raise_error(described_class::NotMounted)
    end
  end

  describe '#mounted_drives' do
    it 'matches registered drives by the serial in their marker, not by volume name' do
      # The 6tb drive was registered as backup-02-6tb but macOS mounted it as "backup-02-6tb 1".
      wrong_name = make_dirs(mount_root, 'backup-02-6tb 1').first
      info.write_marker(wrong_name, serial_number: 'SN-backup-02-6tb', friendly_name: 'backup-02-6tb')
      df_for(wrong_name, 6_000_000, 1_000_000)

      result = info.mounted_drives(drives.values)
      expect(result.size).to eq(1)
      expect(result.first).to have_attributes(serial_number: 'SN-backup-02-6tb', friendly_name: 'backup-02-6tb',
                                              mount_point: wrong_name, capacity_bytes: 6_000_000 * 1024,
                                              used_bytes: 1_000_000 * 1024, free_bytes: 5_000_000 * 1024)
    end

    it 'ignores volumes without a marker and markers for unknown serials' do
      make_dirs(mount_root, 'Macintosh HD', 'nas')
      stranger = make_dirs(mount_root, 'backup-01-3tb').first
      info.write_marker(stranger, serial_number: 'SOMEONE-ELSES-DRIVE', friendly_name: 'backup-01-3tb')
      expect(info.mounted_drives(drives.values)).to be_empty
      expect(fake_shell.calls_to('df')).to be_empty
    end

    it 'returns nothing when the mount root does not exist' do
      expect(described_class.new(mount_root: '/nonexistent', shell: fake_shell).mounted_drives(drives.values)).to eq([])
    end
  end

  describe '#usage' do
    it 'parses df -kP into bytes' do
      df_for('/Volumes/x', 7_814_037_168, 3_907_018_584)
      expect(info.usage('/Volumes/x')).to have_attributes(capacity_bytes: 7_814_037_168 * 1024,
                                                          used_bytes: 3_907_018_584 * 1024,
                                                          free_bytes: 3_907_018_584 * 1024)
      expect(fake_shell.calls.last).to eq(['df', '-kP', '/Volumes/x'])
    end

    it 'raises when df fails or prints garbage' do
      fake_shell.on('df', output: 'df: /Volumes/x: No such file or directory', status: 1)
      expect { info.usage('/Volumes/x') }.to raise_error(described_class::NotMounted)
      fake_shell.on('df', output: "header\nweird output\n", status: 0)
      expect { info.usage('/Volumes/x') }.to raise_error(described_class::NotMounted, /could not parse/)
    end
  end

  describe '#volume_uuid' do
    it 'extracts the Volume UUID from diskutil info' do
      fake_shell.on('diskutil', output: <<~OUT)
           Device Identifier:         disk4s1
           Volume Name:               backup-04-8tb
           Volume UUID:               9E7A6D2C-1B3F-4C5D-8E9F-0A1B2C3D4E5F
      OUT
      expect(info.volume_uuid('/Volumes/backup-04-8tb')).to eq('9E7A6D2C-1B3F-4C5D-8E9F-0A1B2C3D4E5F')
    end

    it 'returns nil when diskutil is unavailable' do
      fake_shell.on('diskutil', output: '', status: 1)
      expect(info.volume_uuid('/Volumes/x')).to be_nil
    end
  end
end
