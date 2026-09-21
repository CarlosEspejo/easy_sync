# frozen_string_literal: true

require 'yaml'
require 'fileutils'

module EasySync
  # Loads ~/.easy_sync/config.yml, writing a commented sample on first run.
  # The file is flat: its keys are the settings below.
  class Config
    HOME_DIR = File.join(Dir.home, '.easy_sync')
    DEFAULT_FILENAME = 'config.yml'

    DEFAULTS = {
      sources: [
        { path: '/Volumes/photos', split: false },  # the whole share is one unit
        { path: '/Volumes/tv', split: true },       # each show is placed on its own
        { path: '/Volumes/movies', split: true }
      ],
      mount_root: '/Volumes',
      reserve: '2gb',       # headroom placement always leaves on a drive: APFS metadata, the .easy_sync copies, rsync temp files
      keep_awake: true,     # hold off idle sleep (caffeinate) for the length of a sync, on macOS
      keep_logs: 20,        # run logs kept under log_dir
      purge: true,          # remove files from the backup once they have been gone from the NAS long enough
      grace_days: 7,        # ...at least this many days
      grace_runs: 2,        # ...and confirmed missing on at least this many separate runs
      scrub_stale_days: 30, # a drive is overdue for `scrub` once it's been this long since it was last fully checked
      # Names skipped when choosing folders to place AND passed to every rsync as
      # --exclude, so they are never copied at any depth (Synology recycle bins and
      # thumbnail dirs, Synology Drive's .sync, macOS metadata, SMB leftovers).
      exclude_folders: ['#recycle', '@eaDir', '.DS_Store', '.sync', '.TemporaryItems', '.Trashes',
                        '.smbdelete*', '.com.apple.timemachine.supported*', '.Spotlight-V100', '.fseventsd'],
      rsync_args: []
    }.freeze

    PATH_KEYS = %i[manifest_path dashboard_path lock_path log_dir mount_root].freeze

    # Comments written next to each key when the file is (re)written.
    KEY_COMMENTS = {
      sources: 'NAS shares, as mounted on this Mac. Manage with: easy_sync add-source / remove-source / sources',
      mount_root: 'where the backup drives appear',
      manifest_path: nil, dashboard_path: nil,
      lock_path: 'refuses a second concurrent sync',
      log_dir: 'one log per sync run', keep_logs: nil,
      reserve: 'headroom placement always leaves on a drive',
      keep_awake: 'caffeinate for the length of a sync',
      purge: 'delete from the drives only after...',
      grace_days: '...this many days missing on the NAS',
      grace_runs: '...confirmed on this many separate runs',
      scrub_stale_days: 'a drive is overdue for `scrub` after this many days unchecked',
      exclude_folders: 'never placed, and excluded from every rsync at any depth',
      rsync_args: 'extra arguments appended to every rsync'
    }.freeze

    SAMPLE = <<~YAML
      # easy_sync configuration. Add your NAS shares with:
      #   easy_sync add-source /Volumes/<share>
      :sources: []
      :mount_root: "/Volumes"                 # where the backup drives appear
      :manifest_path: "~/.easy_sync/manifest.sqlite3"
      :dashboard_path: "~/.easy_sync/dashboard.html"
      :lock_path: "~/.easy_sync/jbod.lock"    # refuses a second concurrent sync
      :log_dir: "~/.easy_sync/logs"           # one log per sync run
      :keep_logs: 20
      :reserve: "2gb"                         # headroom placement always leaves on a drive
      :keep_awake: true                       # caffeinate for the length of a sync
      :purge: true                            # delete from the drives only after...
      :grace_days: 7                          # ...this many days missing on the NAS
      :grace_runs: 2                          # ...confirmed on this many separate runs
      :scrub_stale_days: 30                   # a drive is overdue for `scrub` after this many days unchecked
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

    # Loads the config at +path+, writing the sample first if it is missing.
    # Returns [config, status] where status is :generated or nil.
    def self.load(path = default_path)
      status = nil
      unless File.exist?(path)
        write_sample(path)
        status = :generated
      end
      data = YAML.safe_load_file(path, permitted_classes: [Symbol], symbolize_names: true) || {}
      [new(data, path: path), status]
    end

    def self.write_sample(path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, SAMPLE)
    end

    # Renders +data+ as commented YAML: sources first, then the known keys in
    # order, then anything else. Comments come from KEY_COMMENTS.
    def self.dump(data)
      out = +"# easy_sync configuration. Managed by `easy_sync add-source` and friends;\n# editing by hand is fine too.\n"
      order = [:sources] + DEFAULTS.keys.reject { |k| k == :sources } + (data.keys - DEFAULTS.keys - [:sources])
      order.uniq.each do |key|
        next unless data.key?(key)

        value = data[key]
        comment = KEY_COMMENTS[key]
        if key == :sources
          sources = Array(value)
          out << "#{(sources.empty? ? ':sources: []' : ':sources:').ljust(40)}# #{comment}\n"
          sources.each do |src|
            src = { path: src.to_s, split: false } unless src.is_a?(Hash)
            out << "- :path: #{src[:path].to_s.inspect}\n"
            out << "  #{":split: #{src[:split] ? true : false}".ljust(38)}# #{src[:split] ? 'each subfolder placed on its own' : 'the whole share is one unit'}\n"
          end
        elsif (value.is_a?(Array) || value.is_a?(Hash)) && !value.empty?
          # Collections always go in block form under the key; a one-element
          # array rendered inline is not valid YAML.
          out << "#{":#{key}:".ljust(40)}#{comment ? "# #{comment}" : ''}".rstrip << "\n"
          YAML.dump(value).sub(/\A---\s?/, '').lines.each { |l| out << "  #{l.chomp}\n" unless l.strip.empty? }
        else
          rendered = value.is_a?(Array) || value.is_a?(Hash) ? (value.is_a?(Array) ? '[]' : '{}') \
                                                            : YAML.dump(value).sub(/\A---\s?/, '').lines.map(&:chomp).reject { |l| l == '...' }.join
          line = ":#{key}: #{rendered}"
          out << (comment ? "#{line.ljust(40)}# #{comment}\n" : "#{line}\n")
        end
      end
      out
    end

    # Writes the current data back to +path+ (or the path it was loaded from).
    def save(to = path)
      raise Error, 'no config path to save to' unless to

      FileUtils.mkdir_p(File.dirname(to))
      File.write(to, self.class.dump(data))
      to
    end

    # -- sources, as the CLI edits them --------------------------------

    def source_entries
      Array(data[:sources]).map { |e| e.is_a?(Hash) ? { path: e[:path].to_s, split: e[:split] ? true : false } : { path: e.to_s, split: false } }
    end

    def add_source(path, split:)
      raise Error, "#{path} is already a source" if source_entries.any? { |e| e[:path] == path }

      data[:sources] = source_entries + [{ path: path, split: split }]
    end

    def remove_source(path)
      before = source_entries
      data[:sources] = before.reject { |e| e[:path] == path }
      raise Error, "#{path} is not a source" if data[:sources].size == before.size
    end

    def set_split(path, split)
      entries = source_entries
      entry = entries.find { |e| e[:path] == path } or raise Error, "#{path} is not a source"
      entry[:split] = split
      data[:sources] = entries
    end

    attr_reader :data, :path

    def initialize(data, path: nil)
      @data = data
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
      merged[:reserve_bytes] = Jbod::Placement.parse_size(merged[:reserve])
      merged
    end
  end
end
