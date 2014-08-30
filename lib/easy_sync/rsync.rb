require 'logger'

module EasySync

  class Rsync
    attr_reader :sync_name, :source, :destination, :exclude_file, :last_snapshot, :current, :logging

    def initialize(options)
      @sync_name = options[:sync_name]
      @source = options[:source]
      @destination = options[:destination]
      @exclude_file = options[:exclude_file]
      @logging = options.fetch(:logging){:off}
    end

    def latest_snapshot
      @last_snapshot = Dir["#{destination}/*"].max_by{|s| File.atime s}
    end

    def current_snapshot
      @current = File.join destination, Time.now.strftime("%Y-%m-%d")
    end

    def sync
      commands = [
                  "rsync",
                  "-avhiPH",
                  "--exclude-from", "#{exclude_file}",
                  "--link-dest", "#{latest_snapshot}"
                  ]

      commands << ['--log-file', "#{ENV['HOME']}/easy_sync.log" ] if logging == :on
      commands << ["#{source}", "#{current_snapshot}"]
      commands = commands.flatten

      name = "\n\n\n------------------ Running #{sync_name} ------------------\n\n\n"
      puts name
      puts "latest snapshot #{@last_snapshot}"

      IO.popen(commands).each_line do |l|
        puts l
      end
    end

  end

end
