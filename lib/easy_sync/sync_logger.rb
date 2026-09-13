# frozen_string_literal: true

require 'logger'

module EasySync
  # Logs to a file and echoes to stdout.
  class SyncLogger
    attr_reader :log

    def initialize(path, out: $stdout)
      @log = Logger.new(path)
      @out = out
    end

    def info(message)
      @out.puts message
      log.info message
    end

    def warn(message)
      @out.puts "WARNING: #{message}"
      log.warn message
    end
  end
end
