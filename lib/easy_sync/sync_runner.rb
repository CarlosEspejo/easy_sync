require 'yaml'

module EasySync

  class SyncRunner
    attr_reader :config_file, :config

    def initialize(options)
      @config_file = options.fetch(:config_file){raise "You must provide a path to a config file"}

      generate_yaml unless File.exist?(@config_file)

      @config = YAML.load_file @config_file
      @mode = options[:mode]
    end

    def run
      config.each do |c|
        puts "\n\n\n------------------ Running #{c[:sync_name]} ------------------\n\n\n"
        Rsync.new(c).sync
      end
    end

    private
    def generate_yaml
      File.open(config_file, 'w'){|f| f.puts [{
                                                sync_name: "sample_sync",
                                                source: "/example/path",
                                                destination: "/example/path",
                                                exclude_file: "/example/path"}].to_yaml}

      puts "Generated sample config file: #{config_file}\n\n"
    end

  end

end
