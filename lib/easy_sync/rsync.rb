module EasySync

  class Rsync
    attr_reader :sync_name, :source, :destination, :exclude_file, :last_snapshot, :current, :log_directory

    def initialize(options)
      @sync_name = options[:sync_name]
      @source = options[:source]
      @destination = options[:destination]
      @exclude_file = options[:exclude_file]
      @log_directory = options[:log_directory] || ENV['HOME']
    end

    def latest_snapshot
      @last_snapshot = Dir["#{destination}/*"].max_by{|s| File.mtime s}
    end

    def current_snapshot
      @current = File.join destination, Time.now.strftime("%Y-%m-%d")
    end

    def sync
      commands = [
                  "rsync",
                  "-avhiPH",
                  "--log-file", "#{log_directory}/#{sync_name}.log",
                  "--exclude-from", "#{exclude_file}",
                  "--link-dest", "#{latest_snapshot}",
                  "#{source}", "#{current_snapshot}"
                  ]

      IO.popen(commands).each_line do |l|
        puts l
      end
    end

  end

end
