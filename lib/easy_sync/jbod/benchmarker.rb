# frozen_string_literal: true

require 'fileutils'

module EasySync
  module Jbod
    # `easy_sync benchmark`: measures one mounted drive's sequential write and
    # read speed by writing a test file into its .easy_sync folder, reading it
    # back, and deleting it. A falling rate on one drive is an early failure
    # sign SMART won't necessarily show, so every result is kept (the last
    # Manifest::BENCHMARKS_KEPT per drive) and compared against the drive's own
    # earlier runs. Method and baseline numbers: docs/performance.md.
    #
    # The only thing it ever writes on the drive is TEST_FILE, inside
    # DRIVE_DIR (which rsync, scrub and clean never look at). It is removed
    # again whatever happens, and a leftover from a killed run is removed
    # before the next one starts.
    class Benchmarker
      TEST_FILE = 'benchmark.tmp'
      NOCACHE_CMD = 48 # F_NOCACHE, macOS only; best effort elsewhere
      CHUNK_SIZE = 8 * 1024 * 1024
      # Written round-robin. Generated before the clock starts, so the timing
      # is the drive's, not Random's (~2.7 GB/s here, enough to cost ~7% of a
      # 200 MB/s write if done inline). Spinning drives don't compress or
      # dedupe, so repeating 64 MB of random data is as good as fresh data.
      POOL_CHUNKS = 8
      # A drive's own earlier runs vary by about ±7% (docs/performance.md), so
      # only a drop well past that, against the median of at least
      # MIN_HISTORY earlier runs, is called out.
      SLOWER_THRESHOLD = 0.85
      MIN_HISTORY = 3

      Result = Struct.new(:drive, :bytes, :write_seconds, :read_seconds, :used_bytes, :error, keyword_init: true) do
        def ok? = error.nil?
        def write_mb_s = mb_per_s(write_seconds)
        def read_mb_s = mb_per_s(read_seconds)

        private

        def mb_per_s(seconds) = seconds.to_f.positive? ? (bytes.to_f / seconds) / (1024 * 1024) : 0.0
      end

      # How one run compares with the same drive's earlier ones. +earlier+
      # is how many earlier runs the medians come from; the medians are nil
      # when there are none.
      Comparison = Struct.new(:earlier, :write_median, :read_median, keyword_init: true) do
        def write_change(mb_s) = change(mb_s, write_median)
        def read_change(mb_s) = change(mb_s, read_median)

        def enough? = earlier >= MIN_HISTORY

        # :write and/or :read, for whichever fell below SLOWER_THRESHOLD of its median.
        def slower(write_mb_s, read_mb_s)
          return [] unless enough?

          { write: [write_mb_s, write_median], read: [read_mb_s, read_median] }
            .select { |_, (now, median)| now < median * SLOWER_THRESHOLD }.keys
        end

        private

        def change(mb_s, median) = median&.positive? ? (mb_s / median) - 1 : nil
      end

      def self.compare(earlier_runs)
        median = lambda do |values|
          sorted = values.sort
          mid = sorted.size / 2
          sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
        end
        return Comparison.new(earlier: 0) if earlier_runs.empty?

        Comparison.new(earlier: earlier_runs.size, write_median: median.call(earlier_runs.map(&:write_mb_s)),
                       read_median: median.call(earlier_runs.map(&:read_mb_s)))
      end

      def initialize(timer: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @timer = timer
      end

      # +mounted_drive+ is a MountedDrive struct. Returns a Result; a failure
      # (drive unplugged mid-run, disk full, I/O error) is reported in its
      # +error+ rather than raised, so one bad drive doesn't stop the others.
      def run(mounted_drive, size:)
        path = File.join(mounted_drive.mount_point, DRIVE_DIR, TEST_FILE)
        result = Result.new(drive: mounted_drive.friendly_name, bytes: size, used_bytes: mounted_drive.used_bytes)
        remove(path)
        pool = Array.new(POOL_CHUNKS) { Random.bytes(CHUNK_SIZE) }
        result.write_seconds = timed { write_test_file(path, size, pool) }
        result.read_seconds = timed { read_test_file(path) }
        result
      rescue SystemCallError, IOError => e
        result.error = File.file?(File.join(mounted_drive.mount_point, MARKER_FILE)) ? e.message : 'unmounted mid-run'
        result
      ensure
        remove(path)
      end

      private

      def timed
        started = @timer.call
        yield
        @timer.call - started
      end

      # The closing fsync is inside the timing: without it this measures how
      # fast macOS accepts writes into RAM, not how fast the drive stores them.
      def write_test_file(path, size, pool)
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, 'wb') do |io|
          nocache(io)
          written = 0
          i = 0
          while written < size
            chunk = pool[i % pool.size]
            chunk = chunk.byteslice(0, size - written) if size - written < chunk.bytesize
            written += io.write(chunk)
            i += 1
          end
          io.fsync
        end
      end

      # F_NOCACHE alone still serves pages already in the cache; evicting
      # first makes the read come off the platter (see PageCache).
      def read_test_file(path)
        buffer = String.new(capacity: CHUNK_SIZE)
        File.open(path, 'rb') do |io|
          nocache(io)
          PageCache.evict(io)
          nil while io.read(CHUNK_SIZE, buffer)
        end
      end

      def nocache(io)
        io.fcntl(NOCACHE_CMD, 1)
      rescue SystemCallError, NotImplementedError
        nil # best effort: not every filesystem/platform supports F_NOCACHE
      end

      def remove(path)
        File.delete(path) if File.exist?(path)
      rescue SystemCallError
        nil
      end
    end
  end
end
