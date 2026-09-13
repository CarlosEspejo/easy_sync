# frozen_string_literal: true

module EasySync
  module Jbod
    # Keeps the Mac from idle-sleeping for the life of this process by
    # spawning `caffeinate -i -w <our pid>` as a background child. caffeinate
    # exits on its own the moment the watched process does, so there is
    # nothing to clean up, even after a crash or Ctrl-C. Does nothing when the
    # binary isn't there (Linux, tests).
    class KeepAwake
      CAFFEINATE = '/usr/bin/caffeinate'

      def initialize(executable: CAFFEINATE, spawner: Process.method(:spawn), detach: Process.method(:detach))
        @executable = executable
        @spawner = spawner
        @detach = detach
      end

      def available? = File.executable?(@executable)

      # Returns true if a caffeinate child was started.
      def start(pid = Process.pid)
        return false unless available?

        child = @spawner.call(@executable, '-i', '-w', pid.to_s, in: File::NULL, out: File::NULL, err: File::NULL)
        @detach.call(child)
        true
      rescue SystemCallError
        false
      end
    end
  end
end
