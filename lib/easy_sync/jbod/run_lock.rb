# frozen_string_literal: true

require 'fileutils'

module EasySync
  module Jbod
    # Prevents two long-running commands (sync, scrub, clean, restore) from
    # overlapping: doubled NAS/drive load, and two processes racing over the
    # same state. A PID file at +path+ is the lock; a stale one (its process
    # no longer running) is reclaimed automatically rather than blocking
    # forever. The file's second line names which command holds it, so
    # `status`/the dashboard can say "Scrub running" instead of assuming sync;
    # a lock file with no second line (written before this existed) reads as
    # 'sync', its original and only kind. Every line from the third on is free
    # text the holder can update as it goes (Jbod::ScrubPool uses one line per
    # drive its workers are currently on) without disturbing the mtime that
    # #status reads as the run's start time.
    class RunLock
      class AlreadyRunning < Error; end

      # pid: the process holding the lock. started_at: the lock file's mtime,
      # which is set once when it's written and never touched again for the
      # life of the run, so it doubles as the run's start time. kind: 'sync',
      # 'scrub', 'clean', or 'restore'. current: an Array of the holder's
      # free-form progress notes (see #note), empty if it hasn't set any.
      Status = Struct.new(:pid, :started_at, :kind, :current, keyword_init: true)

      def initialize(path)
        @path = path
      end

      # Runs the block while holding the lock. Raises AlreadyRunning instead of
      # running the block if another live process already holds it.
      def acquire(kind: 'sync')
        if (pid = holder)
          raise AlreadyRunning, "another easy_sync run is already running (pid #{pid}). " \
                                "If that's wrong (the process really is gone), remove #{@path}."
        end

        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, "#{Process.pid}\n#{kind}\n")
        begin
          yield
        ensure
          File.delete(@path) if File.exist?(@path) && pid_in_file == Process.pid
        end
      end

      # Replaces the free-form lines from the third on (one per +names+, empty
      # to clear them) without touching the file's mtime (the run's recorded
      # start time) or releasing the lock. A no-op unless this process is the
      # one actually holding it.
      def note(*names)
        return unless File.exist?(@path) && pid_in_file == Process.pid

        mtime = File.mtime(@path)
        File.write(@path, "#{[Process.pid, kind_in_file, *names].join("\n")}\n")
        File.utime(mtime, mtime, @path)
      end

      # The run currently holding the lock, or nil if none is (a stale lock
      # left by a dead process counts as none).
      def status
        pid = holder or return nil

        Status.new(pid: pid, started_at: File.mtime(@path), kind: kind_in_file, current: current_in_file)
      end

      private

      # The PID holding the lock, or nil if there is none or it's stale.
      def holder
        pid = pid_in_file
        return nil if pid.nil? || pid.zero?

        Process.kill(0, pid)
        pid
      rescue Errno::ESRCH
        nil # no such process: the lock is stale
      end

      def pid_in_file
        return nil unless File.exist?(@path)

        File.read(@path).lines.first.to_s.strip.to_i
      end

      def kind_in_file
        line = File.read(@path).lines[1]
        line ? line.strip : 'sync'
      end

      def current_in_file
        File.read(@path).lines.drop(2).map(&:strip).reject(&:empty?)
      end
    end
  end
end
