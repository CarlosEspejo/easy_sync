# frozen_string_literal: true

require 'yaml'
require 'fileutils'

module EasySync
  # Loads ~/.easy_sync/config.yml, writing a commented sample on first run.
  #
  # The file is flat: its keys are the settings below. Two older layouts are
  # still read: a file at ~/.easy_syncrc.yml is moved into place, and a file
  # with the settings nested under a :jbod: key (with the removed snapshot
  # mode's :logging:/:tasks: beside it) is unwrapped.
  class Config
    HOME_DIR = File.join(Dir.home, '.easy_sync')
    DEFAULT_FILENAME = 'config.yml'
    LEGACY_PATH = File.join(Dir.home, '.easy_syncrc.yml')
    LEGACY_KEYS = %i[jbod logging tasks].freeze

    DEFAULTS = {
      sources: [
        { path: '/Volumes/photos', split: false },  # the whole share is one unit
        { path: '/Volumes/tv', split: true },       # each show is placed on its own
        { path: '/Volumes/movies', split: true }
      ],
      mount_root: '/Volumes',
      keep_awake: true,     # hold off idle sleep (caffeinate) for the length of a sync, on macOS
      keep_logs: 20,        # run logs kept under log_dir
      purge: true,          # remove files from the backup once they have been gone from the NAS long enough
      grace_days: 7,        # ...at least this many days
      grace_runs: 2,        # ...and confirmed missing on at least this many separate runs
      # Names skipped when choosing folders to place AND passed to every rsync as
      # --exclude, so they are never copied at any depth (Synology recycle bins and
      # thumbnail dirs, Synology Drive's .sync, macOS metadata, SMB leftovers).
      exclude_folders: ['#recycle', '@eaDir', '.DS_Store', '.sync', '.TemporaryItems', '.Trashes',
                        '.smbdelete*', '.com.apple.timemachine.supported*', '.Spotlight-V100', '.fseventsd'],
      rsync_args: []
    }.freeze

    PATH_KEYS = %i[manifest_path dashboard_path lock_path log_dir mount_root].freeze

    SAMPLE = <<~YAML
      # easy_sync configuration. Each source is a NAS share mounted on this Mac.
      # `easy_sync plan` measures them and recommends split true/false for each.
      :sources:
      - :path: "/Volumes/photos"
        :split: false                         # the whole share is one unit on one drive
      - :path: "/Volumes/tv"
        :split: true                          # each subfolder is placed on its own
      - :path: "/Volumes/movies"
        :split: true
      :mount_root: "/Volumes"                 # where the backup drives appear
      :manifest_path: "~/.easy_sync/manifest.sqlite3"
      :dashboard_path: "~/.easy_sync/dashboard.html"
      :lock_path: "~/.easy_sync/jbod.lock"    # refuses a second concurrent sync
      :log_dir: "~/.easy_sync/logs"           # one log per sync run
      :keep_logs: 20
      :keep_awake: true                       # caffeinate for the length of a sync
      :purge: true                            # delete from the drives only after...
      :grace_days: 7                          # ...this many days missing on the NAS
      :grace_runs: 2                          # ...confirmed on this many separate runs
      :exclude_folders: ["#recycle", "@eaDir", ".DS_Store", ".sync", ".TemporaryItems", ".Trashes",
                         ".smbdelete*", ".com.apple.timemachine.supported*", ".Spotlight-V100", ".fseventsd"]
      :rsync_args: []                         # extra arguments appended to every rsync
    YAML

    def self.default_path
      File.join(HOME_DIR, DEFAULT_FILENAME)
    end

    # DEFAULTS with the home-relative paths resolved now rather than at load
    # time, so HOME_DIR is honoured wherever it points (tests redirect it).
    def self.defaults
      DEFAULTS.merge(manifest_path: File.join(HOME_DIR, 'manifest.sqlite3'),
                     dashboard_path: File.join(HOME_DIR, 'dashboard.html'),
                     lock_path: File.join(HOME_DIR, 'jbod.lock'),
                     log_dir: File.join(HOME_DIR, 'logs'))
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
      File.write(path, SAMPLE)
    end

    attr_reader :data, :path

    # +data+ may be the flat layout or the old nested one.
    def initialize(data, path: nil)
      @data = data.key?(:jbod) ? data[:jbod].to_h.merge(data.reject { |k, _| LEGACY_KEYS.include?(k) }) : data
      @data = @data.reject { |k, _| LEGACY_KEYS.include?(k) }
      @path = path
    end

    def [](key) = settings[key]

    # Merged settings with `~` expanded in every path, so a config copied
    # from the README ("~/.easy_sync/...") never creates a literal "~" directory.
    def settings
      merged = self.class.defaults.merge(data)
      PATH_KEYS.each { |k| merged[k] = File.expand_path(merged[k]) if merged[k].is_a?(String) }
      merged[:sources] = Array(merged[:sources]).map do |e|
        e.is_a?(Hash) ? e.merge(path: File.expand_path(e[:path].to_s)) : File.expand_path(e.to_s)
      end
      merged[:config_path] = path   # so a copy of the config can travel with the drives
      merged
    end
  end
end
