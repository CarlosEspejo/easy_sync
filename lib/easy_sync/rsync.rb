module EasySync

  class Rsync
    attr_reader :source, :destination, :last_snapshot, :current

    def initialize(source, destination)
      @source = source
      @destination = destination
    end

    def latest_snapshot
      @last_snapshot = Dir["#{destination}/*"].max_by{|s| File.mtime s}
    end

    def current_snapshot
      @current = File.join destination, Time.now.strftime("%Y-%m-%d")
    end

    def sync
      IO.popen(["rsync", "-avP", "#{File.join(source, '/')}", "#{current_snapshot}"]).each_line do |l|
        puts l
      end
    end

  end

end
