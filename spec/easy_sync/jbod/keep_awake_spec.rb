# frozen_string_literal: true

RSpec.describe EasySync::Jbod::KeepAwake do
  let(:spawned) { [] }
  let(:detached) { [] }
  let(:fake_bin) { write_file(File.join(temp_dir, 'caffeinate'), "#!/bin/sh\n").tap { |p| File.chmod(0o755, p) } }

  def keeper(executable)
    described_class.new(executable: executable, spawner: ->(*a) { spawned << a; 4242 }, detach: ->(pid) { detached << pid })
  end

  it 'spawns caffeinate -i -w against the given pid and detaches it' do
    expect(keeper(fake_bin).start(1234)).to be true
    expect(spawned.size).to eq(1)
    expect(spawned.first[0..3]).to eq([fake_bin, '-i', '-w', '1234'])
    expect(spawned.first.last).to include(out: File::NULL, err: File::NULL)
    expect(detached).to eq([4242])
  end

  it 'defaults to its own pid' do
    keeper(fake_bin).start
    expect(spawned.first[3]).to eq(Process.pid.to_s)
  end

  it 'does nothing where caffeinate does not exist' do
    expect(keeper(File.join(temp_dir, 'nope')).start).to be false
    expect(spawned).to be_empty
  end

  it 'reports false rather than raising when the spawn fails' do
    k = described_class.new(executable: fake_bin, spawner: ->(*) { raise Errno::EAGAIN }, detach: ->(_) {})
    expect(k.start).to be false
  end
end
