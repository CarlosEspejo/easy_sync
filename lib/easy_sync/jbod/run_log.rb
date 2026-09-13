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

      def self.open(dir, keep: 20, out: $stdout, clock: Time)
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "sync-#{clock.now.strftime('%Y%m%d-%H%M%S')}.log")
        prune(dir, keep: keep - 1)
        new(File.open(path, 'a'), out: out, path: path)
      end

      # Keeps the newest +keep+ sync logs in +dir+.
      def self.prune(dir, keep:)
        logs = Dir.glob(File.join(dir, 'sync-*.log')).sort
        (logs.size - [keep, 0].max).clamp(0, logs.size).times { |i| File.delete(logs[i]) }
      end

      def initialize(file, out:, path: nil)
        @file = file
        @out = out
        @path = path
        @file.sync = true
      end

      def puts(*lines)
        @out.puts(*lines)
        lines = [''] if lines.empty?
        lines.flatten.each { |l| @file.puts(l) unless l.to_s.include?("\r") }
      end

      def print(*args)
        @out.print(*args)
        @file.print(*args) unless args.join.include?("\r")
      end

      def close = @file.close
    end
  end
end
