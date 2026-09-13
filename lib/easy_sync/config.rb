# frozen_string_literal: true

require 'yaml'
require 'fileutils'

module EasySync
  # Loads ~/.easy_sync/config.yml, generating a sample file on first run.
  # A config left at the original gem's location, ~/.easy_syncrc.yml, is moved
  # into place the first time it is looked for.
  #
  # The file has two independent sections:
  #   :logging / :tasks  -> the original incremental snapshot mode
  #   :jbod              -> folder-level mirroring onto JBOD drives
  class Config
    HOME_DIR = File.join(Dir.home, '.easy_sync')
    DEFAULT_FILENAME = 'config.yml'
    LEGACY_PATH = File.join(Dir.home, '.easy_syncrc.yml')

    JBOD_DEFAULTS = {
      sources: [
        { path: '/Volumes/photos', split: false },  # the whole share is one unit
        { path: '/Volumes/tv', split: true },       # each show is placed on its own
        { path: '/Volumes/movies', split: true }
      ],
      mount_root: '/Volumes',
      manifest_path: File.join(HOME_DIR, 'manifest.sqlite3'),
      dashboard_path: File.join(HOME_DIR, 'dashboard.html'),
      lock_path: File.join(HOME_DIR, 'jbod.lock'),   # refuses a second concurrent `jbod sync`
      keep_awake: true,     # hold off idle sleep (caffeinate) for the length of a sync, on macOS
      purge: true,          # remove files from the backup once they have been gone from the NAS long enough
      grace_days: 7,        # ...at least this many days
      grace_runs: 2,        # ...and confirmed missing on at least this many separate runs
      exclude_folders: ['#recycle', '@eaDir', '.DS_Store'],
      rsync_args: []
    }.freeze

    def self.default_path
      File.join(HOME_DIR, DEFAULT_FILENAME)
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

    # Loads the config at +path+. If it is missing: moves a legacy
    # ~/.easy_syncrc.yml there when one exists, otherwise writes the sample.
    # Returns [config, status] where status is :generated, :migrated, or nil.
    def self.load(path = default_path, legacy_path: LEGACY_PATH)
      status = nil
      unless File.exist?(path)
        FileUtils.mkdir_p(File.dirname(path))
        if legacy_path && File.exist?(legacy_path)
          File.rename(legacy_path, path)
          status = :migrated
        else
          write_sample(path)
          status = :generated
        end
      end
      data = YAML.safe_load_file(path, permitted_classes: [Symbol], symbolize_names: true) || {}
      [new(data, path: path), status]
    end

    def self.write_sample(path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, sample.to_yaml)
    end

    attr_reader :data, :path

    def initialize(data, path: nil)
      @data = data
      @path = path
    end

    def [](key) = data[key]

    def logging = data.fetch(:logging, :off)

    def tasks = data.fetch(:tasks, [])

    PATH_KEYS = %i[manifest_path dashboard_path lock_path mount_root].freeze

    # Merged JBOD settings with `~` expanded in every path, so a config copied
    # from the README ("~/.easy_sync/...") never creates a literal "~" directory.
    def jbod
      merged = JBOD_DEFAULTS.merge(data.fetch(:jbod, {}))
      PATH_KEYS.each { |k| merged[k] = File.expand_path(merged[k]) if merged[k].is_a?(String) }
      merged[:sources] = Array(merged[:sources]).map do |e|
        e.is_a?(Hash) ? e.merge(path: File.expand_path(e[:path].to_s)) : File.expand_path(e.to_s)
      end
      merged[:config_path] = path   # so a copy of the config can travel with the drives
      merged
    end
  end
end
