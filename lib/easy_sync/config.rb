# frozen_string_literal: true

require 'yaml'

module EasySync
  # Loads ~/.easy_syncrc.yml, generating a sample file on first run.
  #
  # The file has two independent sections:
  #   :logging / :tasks  -> the original incremental snapshot mode
  #   :jbod              -> folder-level mirroring onto JBOD drives
  class Config
    DEFAULT_FILENAME = '.easy_syncrc.yml'

    JBOD_DEFAULTS = {
      sources: [
        { path: '/Volumes/photos', split: false },  # the whole share is one unit
        { path: '/Volumes/tv', split: true },       # each show is placed on its own
        { path: '/Volumes/movies', split: true }
      ],
      mount_root: '/Volumes',
      manifest_path: "#{Dir.home}/.easy_sync/manifest.sqlite3",
      dashboard_path: "#{Dir.home}/.easy_sync/dashboard.html",
      warn_threshold: 0.85,
      delete: true,
      exclude_folders: ['#recycle', '@eaDir', '.DS_Store'],
      rsync_args: []
    }.freeze

    def self.default_path
      File.join(Dir.home, DEFAULT_FILENAME)
    end

    def self.sample
      {
        logging: :on,
        tasks: [{
          sync_name: 'sample_sync',
          source: '[/example/path]',
          destination: '[/example/path]',
          exclude_file: '[/example/path]'
        }],
        jbod: JBOD_DEFAULTS.dup
      }
    end

    # Loads the config at +path+, writing the sample first if it is missing.
    # Returns [config, generated?].
    def self.load(path = default_path)
      generated = false
      unless File.exist?(path)
        write_sample(path)
        generated = true
      end
      [new(YAML.safe_load_file(path, permitted_classes: [Symbol], symbolize_names: true) || {}), generated]
    end

    def self.write_sample(path)
      File.write(path, sample.to_yaml)
    end

    attr_reader :data

    def initialize(data)
      @data = data
    end

    def [](key) = data[key]

    def logging = data.fetch(:logging, :off)

    def tasks = data.fetch(:tasks, [])

    def jbod
      JBOD_DEFAULTS.merge(data.fetch(:jbod, {}))
    end
  end
end
