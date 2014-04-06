require 'yaml'

module EasySync

  class SyncRunner
    attr_reader :config

    def initialize()
      handle_config
    end

    def run
      config[:tasks].each do |c|
        c[:logging] = config[:logging]
        Rsync.new(c).sync
      end
    end

    private

    def handle_config
      path = "#{ENV["HOME"]}/.easy_syncrc.yml"
      generate_yaml(path) unless File.exist? path
      @config = YAML.load_file path
    end

    def generate_yaml(path)
      File.open(path, 'w') do |f|
        h = {:logging => :on,
             :tasks => [{
                            sync_name: "sample_sync",
                            source: "[/example/path]",
                            destination: "[/example/path]",
                            exclude_file: "[/example/path]"
                          }]}
        f.puts h.to_yaml
      end

      $stderr.puts "Generated sample config file: #{path}\n\n"
    end

  end

end
