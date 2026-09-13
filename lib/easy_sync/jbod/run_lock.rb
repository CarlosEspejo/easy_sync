# frozen_string_literal: true

require 'fileutils'

module EasySync
  module Jbod
    # Prevents two `easy_sync sync` runs from overlapping: doubled NAS
    # load, and two processes racing to place folders on the same free space.
    # A PID file at +path+ is the lock; a stale one (its process no longer
    # running) is reclaimed automatically rather than blocking forever.
    class RunLock
      class AlreadyRunning < Error; end

      # pid: the process holding the lock. started_at: the lock file's mtime,
      # which is set once when it's written and never touched again for the
      # life of the run, so it doubles as the run's start time.
      Status = Struct.new(:pid, :started_at, keyword_init: true)

      def initialize(path)
        @path = path
      end

      # Runs the block while holding the lock. Raises AlreadyRunning instead of
      # running the block if another live process already holds it.
      def acquire
        if (pid = holder)
          raise AlreadyRunning, "another easy_sync sync is already running (pid #{pid}). " \
                                "If that's wrong (the process really is gone), remove #{@path}."
        end

        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, Process.pid.to_s)
        begin
          yield
        ensure
          File.delete(@path) if File.exist?(@path) && File.read(@path).strip == Process.pid.to_s
        end
      end

      # The run currently holding the lock, or nil if none is (a stale lock
      # left by a dead process counts as none).
      def status
        pid = holder or return nil

        Status.new(pid: pid, started_at: File.mtime(@path))
      end

      private

      # The PID holding the lock, or nil if there is none or it's stale.
      def holder
        return nil unless File.exist?(@path)

        pid = File.read(@path).strip.to_i
        return nil if pid.zero?

        Process.kill(0, pid)
        pid
      rescue Errno::ESRCH
        nil # no such process: the lock is stale
      end
    end
  end
end
