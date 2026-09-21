# frozen_string_literal: true

RSpec.describe EasySync::Jbod::PageCache do
  it "evicts a file's cached pages without changing its contents" do
    path = write_file(File.join(temp_dir, 'f.bin'), 'x' * 100_000)
    File.open(path, 'rb') { |io| expect(described_class.evict(io)).to be(true) }
    expect(File.read(path)).to eq('x' * 100_000)
  end

  it 'skips an empty file, which cannot be mapped' do
    path = write_file(File.join(temp_dir, 'empty.bin'), '')
    File.open(path, 'rb') { |io| expect(described_class.evict(io)).to be(false) }
  end

  it 'never raises; a failure just leaves the cache alone' do
    allow(described_class).to receive(:functions).and_raise(Fiddle::DLError)
    path = write_file(File.join(temp_dir, 'f.bin'), 'x')
    File.open(path, 'rb') { |io| expect(described_class.evict(io)).to be(false) }
  end
end
