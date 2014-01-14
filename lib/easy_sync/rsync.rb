module EasySync

  class Rsync
    attr_reader :source, :destination, :exclude_file, :last_snapshot, :current

    def initialize(source, destination, exclude_file="")
      @source = source
      @destination = destination
      @exclude_file = exclude_file
    end

    def latest_snapshot
      @last_snapshot = Dir["#{destination}/*"].max_by{|s| File.mtime s}
    end

    def current_snapshot
      @current = File.join destination, Time.now.strftime("%Y-%m-%d")
    end

    def sync
      IO.popen(["rsync", "-avhiPH", "--exclude-from", "#{exclude_file}", "--link-dest", "#{latest_snapshot}", "#{source}", "#{current_snapshot}"]).each_line do |l|
        puts l
      end
    end

  end

end
