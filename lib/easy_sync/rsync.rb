require 'logger'

module EasySync

  class Rsync
    attr_reader :sync_name, :source, :destination, :exclude_file, :last_snapshot, :current, :logger

    def initialize(options)
      @sync_name = options[:sync_name]
      @source = options[:source]
      @destination = options[:destination]
      @exclude_file = options[:exclude_file]
      #@logger = options.fetch(:logger){Logger.new(STDOUT)}
      #@logger = Logger.new('/dev/null') if @logger == :off
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
                  "--exclude-from", "#{exclude_file}",
                  "--link-dest", "#{latest_snapshot}",
                  "#{source}", "#{current_snapshot}"
                  ]

      name = "\n\n\n------------------ Running #{sync_name} ------------------\n\n\n"
      puts name

      IO.popen(commands).each_line do |l|
        puts l
      end
    end

  end

end
