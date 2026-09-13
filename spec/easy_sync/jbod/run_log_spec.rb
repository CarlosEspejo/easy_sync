# frozen_string_literal: true

RSpec.describe EasySync::Jbod::RunLog do
  let(:dir) { File.join(temp_dir, 'logs') }
  let(:out) { StringIO.new }
  let(:clock) { double('clock', now: Time.utc(2026, 9, 13, 12, 30, 45)) }

  it 'names the log by timestamp and tees every line to both the terminal and the file' do
    log = described_class.open(dir, keep: 5, out: out, clock: clock)
    log.puts 'hello'
    log.puts 'a', 'b'
    log.print 'no newline'
    log.close
    expect(log.path).to eq(File.join(dir, 'sync-20260913-123045.log'))
    expect(out.string).to eq("hello\na\nb\nno newline")
    expect(File.read(log.path)).to eq("hello\na\nb\nno newline")
  end

  it 'keeps rsync progress chunks (carriage-return updates) out of the file but on the terminal' do
    log = described_class.open(dir, keep: 5, out: out, clock: clock)
    log.puts "     32,768   1%    0.00kB/s\r  2,000,000 100%  938.05MB/s (xfr#1, to-chk=0/2)"
    log.puts 'Total file size: 2,000,000 bytes'
    log.close
    expect(out.string).to include('938.05MB/s', 'Total file size')
    expect(File.read(log.path)).to eq("Total file size: 2,000,000 bytes\n")
  end

  it 'prunes old logs so at most keep remain, counting the new one' do
    FileUtils.mkdir_p(dir)
    %w[20260901-000000 20260902-000000 20260903-000000].each { |t| File.write(File.join(dir, "sync-#{t}.log"), '') }
    File.write(File.join(dir, 'unrelated.txt'), '')
    described_class.open(dir, keep: 2, out: out, clock: clock).close
    expect(Dir.children(dir).sort).to eq(%w[sync-20260903-000000.log sync-20260913-123045.log unrelated.txt])
  end
end
