# frozen_string_literal: true

module EasySync
  # Runs every snapshot task from the config file.
  class SyncRunner
    attr_reader :config

    def initialize(config_path: Config.default_path, shell: Shell.new, out: $stdout, err: $stderr)
      @config, status = Config.load(config_path)
      err.puts "Generated sample config file: #{config_path}\n\n" if status == :generated
      err.puts "Moved #{Config::LEGACY_PATH} to #{config_path}\n\n" if status == :migrated
      @shell = shell
      @out = out
    end

    def run
      config.tasks.each do |task|
        Rsync.new(task.merge(logging: config.logging), shell: @shell, out: @out).sync
      end
    end
  end
end
