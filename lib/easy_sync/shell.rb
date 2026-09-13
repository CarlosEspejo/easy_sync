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
    #
    # The child runs in its own process group. On Interrupt that whole group
    # (rsync and its helper processes) gets SIGINT, then SIGTERM if it lingers,
    # whether the interrupt came from a terminal Ctrl-C or from a signal sent
    # to our pid alone (pkill, launchd, an app quitting); without this we would
    # sit blocked until rsync finished the folder it was on.
    def run(argv, echo: true)
      lines = []
      status = nil
      Open3.popen2e(*argv, pgroup: true) do |stdin, stdout_err, wait|
        stdin.close
        begin
          stdout_err.each_line do |line|
            lines << line
            @out.puts line.chomp if echo
          end
          status = wait.value.exitstatus
        rescue Interrupt
          stop_child(wait)
          raise
        end
      end
      Result.new(output: lines.join, status: status)
    end

    def stop_child(wait)
      Process.kill('INT', -wait.pid)   # negative pid: the whole process group
      return if wait.join(5)

      Process.kill('TERM', -wait.pid)
      wait.join(5)
    rescue Errno::ESRCH
      nil # already gone
    end

    # Runs +argv+ quietly and returns the captured output.
    def capture(argv)
      run(argv, echo: false)
    end
  end
end
