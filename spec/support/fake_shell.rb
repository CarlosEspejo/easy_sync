# frozen_string_literal: true

# Stands in for EasySync::Shell. Records every argv and answers from a table of
# stubbed responses, so no test ever needs rsync, df, du, or diskutil.
class FakeShell
  attr_reader :calls

  def initialize
    @calls = []
    @responses = []
  end

  # Register a response. +matcher+ is the command name (String) or a Proc
  # receiving argv. +output+/+status+ may be Procs taking argv.
  def on(matcher, output: '', status: 0)
    @responses << [matcher, output, status]
    self
  end

  def run(argv, echo: true)
    @calls << argv
    matcher, output, status = @responses.reverse.find { |m, _, _| matches?(m, argv) }
    raise "FakeShell: no response registered for #{argv.inspect}" unless matcher

    EasySync::Shell::Result.new(output: value(output, argv), status: value(status, argv))
  end

  def capture(argv) = run(argv, echo: false)

  def calls_to(command) = calls.select { |argv| argv.first == command }

  private

  def matches?(matcher, argv)
    matcher.is_a?(Proc) ? matcher.call(argv) : argv.first == matcher
  end

  def value(v, argv) = v.is_a?(Proc) ? v.call(argv) : v
end

module FakeShellHelpers
  def fake_shell
    @fake_shell ||= FakeShell.new
  end

  def rsync_stats(total: 1_000, transferred: 100)
    <<~OUT
      sending incremental file list
      Number of files: 12 (reg: 10, dir: 2)
      Total file size: #{total.to_s.gsub(/(\d)(?=(\d{3})+$)/, '\1,')} bytes
      Total transferred file size: #{transferred.to_s.gsub(/(\d)(?=(\d{3})+$)/, '\1,')} bytes
      sent 1,234 bytes  received 56 bytes  2,580.00 bytes/sec
    OUT
  end

  def df_output(mount, capacity_kb:, used_kb:)
    "Filesystem 1024-blocks Used Available Capacity Mounted on\n" \
      "/dev/disk4s1 #{capacity_kb} #{used_kb} #{capacity_kb - used_kb} 50% #{mount}\n"
  end
end
