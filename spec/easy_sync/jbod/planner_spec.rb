# frozen_string_literal: true

RSpec.describe EasySync::Jbod::Planner do
  let(:root) { File.join(temp_dir, 'Volumes') }
  let(:projects) { File.join(root, 'projects') }
  let(:pro) { File.join(root, 'pro') }
  let(:synology) { File.join(root, 'synology') }
  let(:settings) do
    { sources: [{ path: projects }, { path: pro }, { path: synology }, { path: File.join(root, 'gone') }],
      exclude_folders: ['#recycle', '@eaDir'] }
  end

  before do
    make_dirs(projects, 'Project A', 'Project B', '#recycle', '.sync')
    make_dirs(pro, 'Course 1', 'Course 2')
    make_dirs(synology, 'bsg')
    write_file(File.join(synology, 'Boxing.mp4'))
    write_file(File.join(synology, '.DS_Store'))
    fake_shell.on('du', output: lambda { |argv|
      argv[2..].map do |p|
        gb = case File.basename(p) when 'Project A' then 9_000 when 'Project B' then 8_700 when 'Course 1' then 3 when 'Course 2' then 2 else 1 end
        "#{gb * 1024 * 1024}\t#{p}\n"
      end.join
    })
  end

  def rows(largest) = described_class.new(settings, shell: fake_shell, largest_drive_bytes: largest).rows.to_h { |r| [File.basename(r.source.path), r] }

  it 'measures each share with one du, skipping excluded and hidden names' do
    r = rows(8 * TB)
    expect(r['projects']).to have_attributes(mounted: true, subfolders: 2, loose_files: 0, size_bytes: 17_700 * GB,
                                       largest_name: 'Project A', largest_subfolder: 9_000 * GB)
    expect(fake_shell.calls_to('du').first).to eq(['du', '-sk', "#{projects}/Project A", "#{projects}/Project B"])
    expect(r['gone']).to have_attributes(mounted: false, reason: 'not mounted (or empty)')
  end

  it 'warns when one folder is bigger than the largest drive, since folders are the unit placed' do
    r = rows(8 * TB)['projects']
    expect(r.fits).to be false
    expect(r.reason).to include('Project A alone is 8.8 TB, bigger than the largest drive currently registered',
                                'will fit once you add a bigger drive')
  end

  it 'says every folder fits when the largest one does, however big the whole share is' do
    expect(rows(10 * TB)['projects']).to have_attributes(fits: true, reason: 'every folder fits on the largest drive')
  end

  it 'counts loose top-level files (they are backed up as one more unit)' do
    expect(rows(8 * TB)['synology']).to have_attributes(loose_files: 1, fits: true)
  end

  it 'gives sizes but no verdict when no drive size is known' do
    r = rows(nil)['projects']
    expect(r.fits).to be_nil
    expect(r.reason).to include('register a drive')
  end

  describe '#rows with only:' do
    it 'measures just the named shares, matched by folder name or full path, without touching the rest' do
      planner = described_class.new(settings, shell: fake_shell, largest_drive_bytes: 8 * TB)
      result = planner.rows(only: ['pro'])
      expect(result.map { |r| File.basename(r.source.path) }).to eq(['pro'])
      expect(fake_shell.calls_to('du').first).to eq(['du', '-sk', "#{pro}/Course 1", "#{pro}/Course 2"])

      result = planner.rows(only: [projects])
      expect(result.map { |r| File.basename(r.source.path) }).to eq(['projects'])
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
