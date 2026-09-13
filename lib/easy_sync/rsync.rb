# frozen_string_literal: true

require 'fileutils'

module EasySync
  # Incremental snapshot mode: every run creates a dated directory under
  # +destination+, hard-linking unchanged files against the previous snapshot.
  class Rsync
    SNAPSHOT_NAME = /\A\d{4}-\d{2}-\d{2}\z/
    KEEP_SNAPSHOTS = 5

    attr_reader :sync_name, :source, :destination, :exclude_file, :logging

    def initialize(options, shell: Shell.new, out: $stdout, clock: Time)
      @sync_name = options[:sync_name]
      @source = options[:source]
      @destination = options[:destination]
      @exclude_file = options[:exclude_file]
      @logging = options.fetch(:logging, :off)
      @shell = shell
      @out = out
      @clock = clock
    end

    # Dated snapshot directories under +destination+, oldest first.
    def snapshots
      Dir.children(destination)
         .select { |name| name.match?(SNAPSHOT_NAME) }
         .sort
         .map { |name| File.join(destination, name) }
    rescue Errno::ENOENT
      []
    end

    def latest_snapshot
      snapshots.last
    end

    def current_snapshot
      File.join(destination, @clock.now.strftime('%Y-%m-%d'))
    end

    def remove_old_backups
      (snapshots - snapshots.last(KEEP_SNAPSHOTS)).each do |path|
        @out.puts "Removing #{path}"
        FileUtils.remove_dir(path, true)
      end
    end

    def command
      argv = ['rsync', '-avhiPH']
      argv += ['--exclude-from', exclude_file] if exclude_file && !exclude_file.empty?
      argv += ['--link-dest', latest_snapshot] if latest_snapshot
      argv += ['--log-file', File.join(Dir.home, 'easy_sync.log')] if logging == :on
      argv + [source, current_snapshot]
    end

    # Runs rsync. Old snapshots are only pruned after a successful sync.
    def sync
      @out.puts "\n------------------ Running #{sync_name} ------------------\n"
      @out.puts "latest snapshot #{latest_snapshot || '(none)'}"

      result = @shell.run(command)
      raise Error, "rsync for #{sync_name} exited with status #{result.status}" unless result.success?

      remove_old_backups
      result
    end
  end
end
