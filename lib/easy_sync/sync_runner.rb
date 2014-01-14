require 'yaml'
require 'pry'

module EasySync

  class SyncRunner
    attr_reader :config_file, :config

    def initialize(options)
      @config_file = options.fetch(:config_file){raise "You must provide a config file"}
      @config = YAML.load_file @config_file
    end

    def run
      config.each do |c|
        puts "------------------ Running #{c[:sync_name]} ------------------\n\n\n"
        Rsync.new(c[:source], c[:destination], c[:exclude_file]).sync
      end
    end

  end

end
