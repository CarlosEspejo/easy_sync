# frozen_string_literal: true

require 'open3'

module EasySync
  # Runs external commands. Streams output to +out+ as it arrives and returns
  # the full output together with the exit status. Everything that shells out
  # goes through here so tests can inject a fake.
  class Shell
    Result = Struct.new(:output, :status, keyword_init: true) do
      def success? = status.zero?
    end

    def initialize(out: $stdout)
      @out = out
    end

    # The same shell, echoing to a different destination (a run log tee).
    def with_out(out) = self.class.new(out: out)

    # Runs +argv+ (an Array, never a shell string) and streams its output.
    def run(argv, echo: true)
      lines = []
      status = nil
      Open3.popen2e(*argv) do |stdin, stdout_err, wait|
        stdin.close
        stdout_err.each_line do |line|
          lines << line
          @out.puts line.chomp if echo
        end
        status = wait.value.exitstatus
      end
      Result.new(output: lines.join, status: status)
    end

    # Runs +argv+ quietly and returns the captured output.
    def capture(argv)
      run(argv, echo: false)
    end
  end
end
