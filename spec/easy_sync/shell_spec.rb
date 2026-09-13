# frozen_string_literal: true

RSpec.describe EasySync::Shell do
  let(:out) { StringIO.new }
  let(:shell) { described_class.new(out: out) }

  it 'streams output and returns it with the exit status' do
    result = shell.run(['sh', '-c', 'echo one; echo two; exit 3'])
    expect(result.output).to eq("one\ntwo\n")
    expect(result.status).to eq(3)
    expect(out.string).to eq("one\ntwo\n")
    expect(shell.capture(['echo', 'quiet']).output).to eq("quiet\n")
  end

  it 'forwards an Interrupt to the running child instead of waiting for it to finish' do
    child_pid = nil
    runner = Thread.new do
      shell.run(['sh', '-c', 'echo $$; sleep 30'])
    rescue Interrupt
      :interrupted
    end
    Timeout.timeout(5) { sleep 0.05 until out.string.match?(/\d+\n/) }
    child_pid = out.string[/\d+/].to_i

    runner.raise(Interrupt)
    expect(runner.value).to eq(:interrupted)
    sleep 0.2
    expect { Process.kill(0, child_pid) }.to raise_error(Errno::ESRCH)   # the sleep is gone, not orphaned
  end
end
