# frozen_string_literal: true

module EasySync
  module Jbod
    # Runs `scrub` against several drives at once: one thread per drive, one
    # drive per thread (never two readers on the same spindle). The work is
    # I/O-bound (MRI releases the GVL during blocking File#read), so threads
    # are enough - no processes, no new gems, none of the process-group
    # signal-forwarding CLAUDE.md warns sync needs. See docs/parallel-scrub.md
    # for the full design and the measured numbers.
    class ScrubPool
      # +open_manifest+ is a lambda returning a fresh Manifest (one per
      # worker: SQLite in WAL, one connection per thread). +scrubber_options+
      # are passed to every worker's Scrubber.new besides manifest/clock/out.
      # +lock+ is the RunLock the caller already holds; workers call
      # +lock.note+ with the full set of drives currently being scrubbed
      # every time that set changes. +deadline+, if given, is a Time shared
      # by every worker (the same one passed to scrubber_options[:deadline]).
      def initialize(jobs:, open_manifest:, lock:, scrubber_options: {}, clock: Time, deadline: nil, out: $stdout)
        @jobs = jobs
        @open_manifest = open_manifest
        @lock = lock
        @scrubber_options = scrubber_options
        @clock = clock
        @deadline = deadline
        @out = out
      end

      # +targets+ are MountedDrive structs. Returns their Scrubber::Result,
      # one per target, in target order (not completion order).
      def run(targets)
        return [] if targets.empty?

        queue = Queue.new
        targets.each_with_index { |target, i| queue << [i, target] }
        results = Array.new(targets.size)
        active = {}
        active_mutex = Mutex.new
        worker_count = [@jobs, targets.size].min

        # Opened here, on the calling thread, before any worker starts:
        # Manifest#initialize runs migrate!, and doing that from several
        # threads at once on a brand new manifest invites SQLite lock errors.
        manifests = Array.new(worker_count) { @open_manifest.call }

        threads = manifests.map do |worker_manifest|
          scrubber = Scrubber.new(worker_manifest, clock: @clock, out: @out, deadline: @deadline, **@scrubber_options)
          Thread.new do
            # #wait_for/#cancel already surface a worker's exception (or the
            # Interrupt cancellation itself raises) through the caller;
            # Ruby's default per-thread stderr report would just be noise on
            # top of that.
            Thread.current.report_on_exception = false
            work(scrubber, queue, results, active, active_mutex)
          end
        end

        begin
          wait_for(threads)
        ensure
          manifests.each(&:close)
        end
        results.compact
      end

      private

      def work(scrubber, queue, results, active, active_mutex)
        loop do
          break if @deadline && @clock.now >= @deadline

          index, target = begin
            queue.pop(true)
          rescue ThreadError # empty
            break
          end

          note_active(active, active_mutex) { active[target.friendly_name] = true }
          begin
            results[index] = scrubber.run(target)
          ensure
            note_active(active, active_mutex) { active.delete(target.friendly_name) }
          end
        end
      end

      def note_active(active, mutex)
        mutex.synchronize do
          yield
          @lock.note(*active.keys)
        end
      end

      # Polls rather than blocking on Thread#join in target order, so a
      # worker that dies out of order (its target was smaller, or it simply
      # failed sooner) is noticed - and its siblings cancelled - right away
      # instead of only once every earlier thread happens to finish too.
      #
      # On Ctrl-C (Interrupt arrives here, since this is what the main thread
      # is blocked in) or an exception raised inside a worker: cancel every
      # other worker with Thread#raise(Interrupt) so each stops at its next
      # file boundary and flushes what it already has, join them all
      # (swallowing the Interrupt that cancellation itself causes), then
      # re-raise the original problem - never silently.
      def wait_for(threads)
        loop do
          threads.each do |t|
            next if t.alive?

            begin
              t.join
            rescue Exception => e
              cancel(threads)
              raise e
            end
          end
          break if threads.all? { |t| !t.alive? }

          sleep 0.02
        end
      rescue Interrupt => e
        cancel(threads)
        raise e
      end

      def cancel(threads)
        threads.each { |t| t.raise(Interrupt) if t.alive? }
        threads.each do |t|
          t.join
        rescue Exception
          nil
        end
      end
    end
  end
end
