# frozen_string_literal: true

RSpec.describe EasySync::Jbod::Tripwire do
  let(:tripwire) { described_class.new(run_files: 500, folder_files: 50, folder_ratio: 0.25) }

  def check(replaced: 0, missing: 0, new_files: 0, source_files: 100)
    EasySync::Jbod::Mirror::Check.new(replaced: Array.new(replaced) { |i| "r#{i}.jpg" },
                                      missing: Array.new(missing) { |i| ["m#{i}.jpg", 'file'] },
                                      junk: [], new_files: new_files, source_files: source_files)
  end

  it 'lets a quiet run through' do
    decision = tripwire.decide({ 'movies/A' => check(replaced: 1), 'movies/B' => check })
    expect(decision.trips).to be_empty
    expect(decision).not_to be_tripped
    expect(decision.run_changed).to eq(1)
  end

  it 'trips a folder with 80 of its 100 files replaced, and nothing else' do
    decision = tripwire.decide({ 'music/Jazz' => check(replaced: 80), 'music/Rock' => check(replaced: 2) })
    expect(decision.trips.map { |t| [t.folder_path, t.replaced, t.scope, t.accepted] }).to eq([['music/Jazz', 80, 'folder', false]])
    expect(decision.blocked).to eq(['music/Jazz'])
    expect(decision.run_tripped).to be(false)
  end

  it 'needs the minimum count too: a 3-file folder with one file replaced does not trip' do
    expect(tripwire.decide({ 'tv/Tiny' => check(replaced: 1, source_files: 3) }).trips).to be_empty
  end

  it 'needs the ratio too: 60 files changed in a 10,000-file share is routine' do
    expect(tripwire.decide({ 'photos/All' => check(replaced: 60, source_files: 10_000) }).trips).to be_empty
  end

  it 'counts a ransomware rename (new file plus a deletion) once, via the deletion' do
    # photo.jpg -> photo.jpg.locked: the source has 100 files, 60 of them new
    # names, and the drive holds 60 files the source no longer has.
    c = check(missing: 60, new_files: 60, source_files: 100)
    expect(c.changed).to eq(60)
    expect(c.files_on_drive).to eq(100)
    expect(tripwire.decide({ 'photos/2024' => c }).blocked).to eq(['photos/2024'])
  end

  it 'trips the whole run when 1,000 single-file folders each change one file, though none trips alone' do
    checks = (1..1_000).to_h { |i| ["movies/M#{i}", check(replaced: 1, source_files: 1)] }
    decision = tripwire.decide(checks)
    expect(decision.run_tripped).to be(true)
    expect(decision.run_changed).to eq(1_000)
    expect(decision.trips.size).to eq(1_000)
    expect(decision.trips.map(&:scope).uniq).to eq(['run'])
  end

  it 'lists only folders that changed in a run trip' do
    checks = { 'a' => check(replaced: 500, source_files: 10_000), 'b' => check }
    expect(tripwire.decide(checks).trips.map(&:folder_path)).to eq(['a'])
  end

  describe 'accepting changes' do
    it 'accepts every trip with true, and still reports them' do
      checks = (1..600).to_h { |i| ["movies/M#{i}", check(replaced: 1, source_files: 1)] }
      decision = tripwire.decide(checks, accept: true)
      expect(decision.run_tripped).to be(false)
      expect(decision).not_to be_tripped
      expect(decision.trips.size).to eq(600)
      expect(decision.trips).to all(have_attributes(accepted: true))
    end

    it 'accepts only the named folders, and leaves them out of the run total' do
      checks = { 'music/Jazz' => check(replaced: 450, source_files: 500), 'music/Rock' => check(replaced: 80) }
      decision = tripwire.decide(checks, accept: ['music/Jazz'])
      expect(decision.run_changed).to eq(80)
      expect(decision.run_tripped).to be(false)
      expect(decision.trips.map { |t| [t.folder_path, t.accepted] }).to eq([['music/Jazz', true], ['music/Rock', false]])
      expect(decision.blocked).to eq(['music/Rock'])
    end

    it 'is a no-op for a folder that does not trip' do
      expect(tripwire.decide({ 'a' => check(replaced: 1) }, accept: ['a']).trips).to be_empty
    end
  end

  it 'never trips with tripwire_run_files: 0' do
    off = described_class.new(run_files: 0, folder_files: 50, folder_ratio: 0.25)
    decision = off.decide({ 'a' => check(replaced: 100_000, source_files: 100_000) })
    expect(decision.trips).to be_empty
    expect(decision.run_changed).to eq(100_000)
  end

  it 'reads its thresholds from the config defaults' do
    t = described_class.from_settings(EasySync::Config.defaults)
    expect([t.run_files, t.folder_files, t.folder_ratio]).to eq([500, 50, 0.25])
  end
end
