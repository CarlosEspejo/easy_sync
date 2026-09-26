# frozen_string_literal: true

RSpec.describe EasySync::Jbod::Backblaze do
  let(:scan) { Time.utc(2026, 9, 26, 13, 47) }

  it 'is nil when Backblaze is not installed, so nothing about it is shown' do
    expect(described_class.read).to be_nil
  end

  it "reads each volume's remaining upload by its hex-encoded mount point" do
    fake_backblaze({ '/Volumes/backup-01-8tb' => { files: 0, bytes: 0, scanned_at: scan },
                     '/Volumes/backup-02-6tb' => { files: 1204, bytes: 320 * 1000**3, scanned_at: scan } })
    bb = described_class.read
    expect(bb.last_completed_at).to eq(Time.utc(2026, 9, 26, 15, 8))
    expect(bb.volume('/Volumes/backup-02-6tb/')).to have_attributes(remaining_files: 1204, scanned_at: scan)

    expect(bb.drive_state('/Volumes/backup-01-8tb', '2026-09-25T02:49:13Z')).to have_attributes(state: :done, label: 'up to date')
    expect(bb.drive_state('/Volumes/backup-02-6tb', '2026-09-25T02:49:13Z'))
      .to have_attributes(state: :uploading, label: 'uploading, 1,204 files (298.0 GB) left')
    expect(bb.drive_state('/Volumes/backup-09-8tb', nil)).to have_attributes(state: :unknown, label: 'not in Backblaze')
  end

  it "does not trust a zero Backblaze counted before easy_sync's last copy onto the drive" do
    fake_backblaze({ '/Volumes/backup-01-8tb' => { files: 0, bytes: 0, scanned_at: scan },
                     '/Volumes/backup-03-8tb' => { files: 0, bytes: 0, scanned_at: nil } })
    bb = described_class.read
    expect(bb.drive_state('/Volumes/backup-01-8tb', '2026-09-26T14:00:00Z'))
      .to have_attributes(state: :waiting, label: 'not scanned since the last sync')
    expect(bb.drive_state('/Volumes/backup-01-8tb', nil).state).to eq(:done) # never copied anything
    expect(bb.drive_state('/Volumes/backup-03-8tb', nil).state).to eq(:waiting) # never scanned
  end

  it 'looks up a drive that is not connected at its usual mount point' do
    fake_backblaze({ '/Volumes/backup-01-8tb' => { files: 3, bytes: 30, scanned_at: scan } })
    drive = EasySync::Jbod::Drive.new(serial_number: 'S1', friendly_name: 'backup-01-8tb')
    states = described_class.read.drive_states([drive], mounted: {}, mount_root: '/Volumes', last_copied_at: {})
    expect(states['S1'].state).to eq(:uploading)
  end
end
