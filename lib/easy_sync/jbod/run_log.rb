# frozen_string_literal: true

require 'fileutils'
require 'time'

module EasySync
  module Jbod
    # Tees everything a sync prints into ~/.easy_sync/logs/sync-<timestamp>.log
    # as it happens, so a multi-day run has a record even if the terminal is
    # gone. rsync's in-place progress chunks (carriage-return updates) are kept
    # off disk; the per-folder --stats block that follows them has the totals.
    class RunLog
      attr_reader :path

      # +prefix+ names the run kind ('sync' or 'scrub'), so each is pruned
      # separately: scrub-*.log files never push out sync-*.log files, or the
      # other way around.
      def self.open(dir, keep: 20, out: $stdout, clock: Time, prefix: 'sync')
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "#{prefix}-#{clock.now.strftime('%Y%m%d-%H%M%S')}.log")
        prune(dir, keep: keep - 1, prefix: prefix)
        new(File.open(path, 'a'), out: out, path: path)
      end

      # Keeps the newest +keep+ logs matching +prefix+ in +dir+.
      def self.prune(dir, keep:, prefix: 'sync')
        logs = Dir.glob(File.join(dir, "#{prefix}-*.log")).sort
        (logs.size - [keep, 0].max).clamp(0, logs.size).times { |i| File.delete(logs[i]) }
      end

      def initialize(file, out:, path: nil)
        @file = file
        @out = out
        @path = path
        @file.sync = true
        @mutex = Mutex.new   # Jbod::ScrubPool's workers all write through the same RunLog
      end

      def puts(*lines)
        @mutex.synchronize do
          @out.puts(*lines)
          lines = [''] if lines.empty?
          lines.flatten.each { |l| @file.puts(l) unless l.to_s.include?("\r") }
        end
      end

      def print(*args)
        @mutex.synchronize do
          @out.print(*args)
          @file.print(*args) unless args.join.include?("\r")
        end
      end

      def close = @file.close
    end
  end
end
