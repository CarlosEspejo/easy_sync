require 'yaml'

module EasySync

  class SyncRunner
    attr_reader :config_file, :config, :logger

    def initialize(options)
      @config_file = options.fetch(:config_file){raise "You must provide a path to a config file"}

      generate_yaml unless File.exist?(@config_file)

      @config = YAML.load_file @config_file

      #@logger = logging(@config.fetch(:logger){:stdout})
    end

    def run
      config[:mappings].each do |c|
        Rsync.new(c).sync
      end
    end

    private
    def generate_yaml
      File.open(config_file, 'w') do |f|
        h = {:logger => :stdout,
             :mappings => [{
                            sync_name: "sample_sync",
                            source: "/example/path",
                            destination: "/example/path",
                            exclude_file: "/example/path"
                          }]}
        puts h.to_yaml
      end

       puts "Generated sample config file: #{config_file}\n\n"
    end

    def logging(opt)
      if opt == :off
        SyncLogger.new('/dev/null')
      elsif opt == :stdout
        SyncLogger.new(STDOUT) if opt == :stdout
      else
        SyncLogger.new(opt)
      end
    end

  end

end
