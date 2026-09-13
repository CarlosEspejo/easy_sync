# frozen_string_literal: true

RSpec.describe EasySync::Jbod::Planner do
  let(:root) { File.join(temp_dir, 'Volumes') }
  let(:tv) { File.join(root, 'tv') }
  let(:pro) { File.join(root, 'pro') }
  let(:synology) { File.join(root, 'synology') }
  let(:settings) do
    { sources: [{ path: tv, split: false }, { path: pro, split: true }, { path: synology, split: true }, { path: File.join(root, 'gone'), split: false }],
      exclude_folders: ['#recycle', '@eaDir'] }
  end

  before do
    make_dirs(tv, 'Show A', 'Show B', '#recycle', '.sync')
    make_dirs(pro, 'Course 1', 'Course 2')
    make_dirs(synology, 'bsg')
    write_file(File.join(synology, 'Boxing.mp4'))
    write_file(File.join(synology, '.DS_Store'))
    fake_shell.on('du', output: lambda { |argv|
      argv[2..].map do |p|
        gb = case File.basename(p) when 'Show A' then 9_000 when 'Show B' then 8_700 when 'Course 1' then 3 when 'Course 2' then 2 else 1 end
        "#{gb * 1024 * 1024}\t#{p}\n"
      end.join
    })
  end

  def rows(largest) = described_class.new(settings, shell: fake_shell, largest_drive_bytes: largest).rows.to_h { |r| [File.basename(r.source.path), r] }

  it 'measures each share with one du, skipping excluded and hidden names' do
    r = rows(8 * TB)
    expect(r['tv']).to have_attributes(mounted: true, subfolders: 2, loose_files: 0, size_bytes: 17_700 * GB,
                                       largest_name: 'Show A', largest_subfolder: 9_000 * GB)
    expect(fake_shell.calls_to('du').first).to eq(['du', '-sk', "#{tv}/Show A", "#{tv}/Show B"])
    expect(r['gone']).to have_attributes(mounted: false, reason: 'not mounted (or empty)')
  end

  it 'insists on split when the share is larger than the largest drive, and flags the mismatch' do
    r = rows(8 * TB)['tv']
    expect(r.recommend_split).to be true
    expect(r.reason).to include('larger than the largest drive')
    expect(r).to be_mismatch
    expect(r.fits).to be false
    expect(r.reason).to include('Show A alone is 8.8 TB, bigger than the largest drive currently registered',
                                'will fit once you add a bigger drive')
  end

  it 'suggests split above half the largest drive, whole below it' do
    expect(rows(30 * TB)['tv']).to have_attributes(recommend_split: true, fits: true)   # 17.3 TB > 15 TB
    expect(rows(30 * TB)['tv'].reason).to include('more than half')
    expect(rows(40 * TB)['pro']).to have_attributes(recommend_split: false)
    expect(rows(40 * TB)['pro'].reason).to include('fits comfortably')
    expect(rows(40 * TB)['pro']).to be_mismatch   # configured split: true
  end

  it 'requires whole for a share with loose files, whatever its size' do
    r = rows(8 * TB)['synology']
    expect(r).to have_attributes(recommend_split: false, loose_files: 1)
    expect(r.reason).to include('1 loose file at the top level')
  end

  it 'gives sizes but no verdict when no drive size is known' do
    r = rows(nil)['tv']
    expect(r.recommend_split).to be_nil
    expect(r.reason).to include('register a drive')
    expect(r).not_to be_mismatch
  end

  describe '#rows with only:' do
    it 'measures just the named shares, matched by folder name or full path, without touching the rest' do
      planner = described_class.new(settings, shell: fake_shell, largest_drive_bytes: 8 * TB)
      result = planner.rows(only: ['pro'])
      expect(result.map { |r| File.basename(r.source.path) }).to eq(['pro'])
      expect(fake_shell.calls_to('du').first).to eq(['du', '-sk', "#{pro}/Course 1", "#{pro}/Course 2"])

      result = planner.rows(only: [tv])
      expect(result.map { |r| File.basename(r.source.path) }).to eq(['tv'])
    end

    it 'returns an empty list when nothing matches' do
      planner = described_class.new(settings, shell: fake_shell, largest_drive_bytes: 8 * TB)
      expect(planner.rows(only: ['nope'])).to eq([])
    end

    it 'measures everything when only: is nil' do
      planner = described_class.new(settings, shell: fake_shell, largest_drive_bytes: 8 * TB)
      expect(planner.rows(only: nil).size).to eq(4)
    end
  end
end
