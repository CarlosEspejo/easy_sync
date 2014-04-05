require 'yaml'

module EasySync

  class SyncRunner
    attr_reader :config_file, :config, :log_setting, :test_config_path

    def initialize(options={})
      @config_file = options.fetch(:config_file){:not_provided}
      handle_config
    end

    def run
      config[:mappings].each do |c|
        Rsync.new(c).sync
      end
    end

    private

    def handle_config
      path = "#{ENV["HOME"]}/.easy_syncrc.yml"
      generate_yaml(path) if config_file == :not_provided
      @config = YAML.load_file path
    end

    def generate_yaml(path)
      File.open(path, 'w') do |f|
        h = {:rsync_log_setting => :on,
             :mappings => [{
                            sync_name: "sample_sync",
                            source: "[/example/path]",
                            destination: "[/example/path]",
                            exclude_file: "[/example/path]"
                          }]}
        f.puts h.to_yaml
      end

      STDERR.puts "Generated sample config file: #{path}\n\n"
    end

  end

end
