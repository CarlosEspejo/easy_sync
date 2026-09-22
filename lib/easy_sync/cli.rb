# frozen_string_literal: true

require 'optparse'
require 'time'

module EasySync
  # Command-line entry point.
  class CLI
    # [group, [[command, description], ...]] in the order a new user meets them.
    COMMAND_GROUPS = [
      ['Set up, once', [
        ['add-source PATH [--split | --whole]', 'add a NAS share (mounted on this Mac); split/whole is inferred unless given'],
        ['register-drive MOUNT_POINT [--name NAME] [--serial SERIAL]', 'add a backup drive (mounted and unlocked)'],
        ['plan [SHARE ...] [--largest-drive SIZE] [--apply]', 'measure each share (or just the ones named) and recommend split or whole; --apply writes it']
      ]],
      ['Back up', [
        ['sync [--dry-run] [--no-purge] [--no-keep-awake]', 'mirror the shares onto the drives'],
        ['status [--all]', 'whether a sync is running, drives, their health, and a folder summary; --all lists every folder'],
        ['dashboard', 'regenerate the HTML report']
      ]],
      ['Maintain', [
        ['pending', 'deletion candidates and when each expires'],
        ['clean [--dry-run]', 'remove excluded junk (#recycle, .DS_Store, ...) from the drives now'],
        ['scrub [NAME ...] [--all] [--jobs N] [--for DURATION] [--dry-run] [--no-keep-awake]',
         'read every tracked file back off a drive and check it against its baseline; catches bit rot rsync cannot see'],
        ['benchmark [NAME ...] [--all] [--size SIZE] [--history]',
         "time a drive's sequential write and read against its own earlier runs; a slowing drive can be failing"],
        ['history [FOLDER]', 'where a folder has lived'],
        ['reassign FOLDER DRIVE_NAME [--note TEXT] [--force]', 'point a folder at a different drive (moves no data); refuses a drive without room unless --force'],
        ['rename-drive OLD_NAME NEW_NAME', "relabel a drive, or swap two drives' names; touches no data"],
        ['replace-drive OLD_NAME [--to NEW_NAME] [--copy]', 'retire a drive; hand its folders to NEW, or let the next sync re-place them'],
        ['verify-drive NAME [--note TEXT]', 'record that a full-surface scan (SpinRite etc.) found no new defects; resets the reallocated-sector baseline'],
        ['restore FOLDER|SHARE [...] | --all [--dry-run]', 'copy folders back onto the NAS from wherever they live (reverse of sync)'],
        ['remove-source PATH', 'stop backing up a share (drives are left alone)'],
        ['sources', 'list the configured shares']
      ]]
    ].freeze

    USAGE = begin
      width = COMMAND_GROUPS.flat_map { |_, cmds| cmds.map { |c, _| c.length } }.max + 2
      lines = ['Usage: easy_sync [--config PATH] <command> [options]', '']
      COMMAND_GROUPS.each do |group, cmds|
        lines << "#{group}:"
        cmds.each { |c, d| lines << "  #{c.ljust(width)}#{d}" }
        lines << ''
      end
      lines << 'Global options:'
      lines << "  #{'--config PATH'.ljust(width)}use this config file (default ~/.easy_sync/config.yml; EASY_SYNC_CONFIG does the same)"
      lines << "  #{'--version'.ljust(width)}print the version"
      lines << "  #{'--help'.ljust(width)}this text"
      "#{lines.join("\n")}\n"
    end

    def initialize(argv, out: $stdout, err: $stderr, config_path: nil, shell: Shell.new, env: ENV,
                   keep_awake: Jbod::KeepAwake.new, clock: Time)
      @argv = argv.dup
      @out = out
      @err = err
      @shell = shell
      @keep_awake = keep_awake
      @clock = clock
      @config_path = config_path || env['EASY_SYNC_CONFIG'] || Config.default_path
    end

    def run
      parse_global_options!
      command = @argv.shift
      case command
      when nil, '-h', '--help', 'help'
        @out.puts USAGE
        @out.puts get_started_hint if nothing_configured?
      when '-v', '--version', 'version' then @out.puts "easy_sync #{VERSION}"
      when 'add-source' then add_source(@argv)
      when 'remove-source' then remove_source(@argv)
      when 'sources' then list_sources
      when 'sync' then sync(@argv)
      when 'register-drive' then register_drive(@argv)
      when 'replace-drive' then replace_drive(@argv)
      when 'restore' then restore(@argv)
      when 'status' then status(@argv)
      when 'history' then history(@argv.first)
      when 'reassign' then reassign(@argv)
      when 'rename-drive' then rename_drive(@argv)
      when 'verify-drive' then verify_drive(@argv)
      when 'pending' then pending
      when 'clean' then clean(@argv)
      when 'scrub' then return scrub(@argv)
      when 'benchmark' then return benchmark(@argv)
      when 'plan' then plan(@argv)
      when 'dashboard' then dashboard
      else
        @err.puts "Unknown command: #{command}\n\n#{USAGE}"
        return 1
      end
      0
    rescue Error, OptionParser::ParseError => e
      @err.puts "error: #{e.message}"
      1
    rescue Interrupt
      # Ctrl-C. Everything is resumable: the lock and log are released by
      # their ensure blocks, caffeinate exits with us, rsync's own temp file for
      # an in-flight rsync copy is removed by rsync, and whatever folder or
      # file was in progress simply gets processed again next run.
      @err.puts "\nInterrupted. Nothing is lost: run the same command again to pick up where this left off."
      130
    end

    private

    # Help must never fail, whatever state the config is in.
    def nothing_configured?
      config.source_entries.empty?
    rescue StandardError
      false
    end

    def get_started_hint
      "Nothing is configured yet. To get started:\n" \
        "  easy_sync add-source /Volumes/<share>            once per NAS share\n" \
        "  easy_sync register-drive /Volumes/<drive>        once per backup drive\n" \
        "  easy_sync plan --apply\n" \
        "  easy_sync sync --dry-run\n" \
        "  easy_sync sync\n"
    end

    # Global options come before the command: `easy_sync --config x sync`.
    def parse_global_options!
      while (arg = @argv.first)
        case arg
        when '--config'
          @argv.shift
          @config_path = @argv.shift or raise Error, "--config needs a path\n\n#{USAGE}"
        when /\A--config=(.+)\z/
          @argv.shift
          @config_path = Regexp.last_match(1)
        else
          break
        end
      end
    end

    def config
      @config ||= begin
        cfg, status = Config.load(@config_path)
        @err.puts "Generated sample config file: #{@config_path}" if status == :generated
        cfg
      end
    end

    def settings = config.settings

    def manifest
      @manifest ||= Jbod::Manifest.open(settings[:manifest_path])
    end

    def volume_info
      @volume_info ||= Jbod::VolumeInfo.new(mount_root: settings[:mount_root], shell: @shell)
    end

    def sync(args)
      opts = { dry_run: false, purge: nil, keep_awake: settings.fetch(:keep_awake, true) }
      OptionParser.new do |o|
        o.on('--dry-run', 'Show what rsync and the purge would do without changing anything') { opts[:dry_run] = true }
        o.on('--no-purge', 'Sync but do not delete expired files from the drives') { opts[:purge] = false }
        o.on('--no-keep-awake', 'Let the Mac sleep during this run (default: caffeinate keeps it awake)') { opts[:keep_awake] = false }
      end.parse!(args)
      version = Jbod::Mirror.check_version!(@shell)
      Jbod::RunLock.new(settings[:lock_path]).acquire(kind: 'sync') do
        log = Jbod::RunLog.open(settings[:log_dir], keep: settings[:keep_logs], out: @out, clock: @clock)
        begin
          log.puts "easy_sync #{VERSION} · #{@clock.now.strftime('%Y-%m-%d %H:%M:%S %Z')} · rsync #{version}" \
                   "#{' · DRY RUN' if opts[:dry_run]} · log #{log.path}"
          log.puts 'Keeping the Mac awake for this run (caffeinate).' if opts[:keep_awake] && @keep_awake.start
          Jbod::Runner.new(settings, manifest: manifest, volume_info: volume_info, shell: @shell.with_out(log),
                                     out: log, dry_run: opts[:dry_run], purge: opts[:purge], clock: @clock).run
          log.puts 'Sync finished (ran to completion, not interrupted).'
        rescue Interrupt
          # Without this, the only way to tell an interrupted run from a
          # completed one is the absence of the line above - which meant
          # reading two log files and comparing timestamps to work out that a
          # "still running" status was actually a fresh restart after Ctrl-C.
          log.puts 'Sync interrupted (Ctrl-C) before it finished. Nothing was lost; a later `sync` resumes it.'
          raise
        ensure
          log.close
        end
      end
    end

    # Removes anything matching exclude_folders from the placed folders on
    # every mounted drive, without waiting for the deletion grace period.
    def clean(args)
      dry_run = false
      OptionParser.new { |o| o.on('--dry-run', 'List what would be removed') { dry_run = true } }.parse!(args)
      # A dry run only reads, so it may look while a sync is running.
      lock = dry_run ? ->(**, &blk) { blk.call } : Jbod::RunLock.new(settings[:lock_path]).method(:acquire)
      lock.call(kind: 'clean') do
        mounted = volume_info.mounted_drives(manifest.drives)
        raise Error, 'no registered drive is mounted' if mounted.empty?

        @out.puts "#{dry_run ? 'Would remove' : 'Removing'} entries matching #{settings[:exclude_folders].join(', ')} " \
                  "from #{mounted.map(&:friendly_name).join(', ')}:"
        result = Jbod::Cleaner.new(manifest, excludes: settings[:exclude_folders], out: @out).run(mounted, dry_run: dry_run)
        if dry_run
          @out.puts "#{result.would_remove.size} entr#{result.would_remove.size == 1 ? 'y' : 'ies'} would be removed."
        else
          @out.puts "Removed #{result.removed.size} entr#{result.removed.size == 1 ? 'y' : 'ies'}, " \
                    "#{Jbod::Placement.format_bytes(result.bytes)} freed."
        end
      end
    end

    # Reads every tracked file on one or more drives back off the platter and
    # compares it to its SHA-256 baseline, catching bit rot that rsync's
    # quick size/mtime check cannot see. See docs/integrity-scan.md.
    def scrub(args)
      opts = { dry_run: false, all: false, keep_awake: settings.fetch(:keep_awake, true), jobs: settings[:scrub_jobs] }
      OptionParser.new do |o|
        o.on('--all', 'Scrub every mounted, non-retired drive, stalest first') { opts[:all] = true }
        o.on('--jobs N', Integer, 'Scrub this many drives at once (default: config scrub_jobs)') { |v| opts[:jobs] = v }
        o.on('--for DURATION', 'Stop after this long (e.g. 90m, 8h, 2d); default runs to completion') { |v| opts[:for] = v }
        o.on('--dry-run', 'Walk and report what would be hashed, without hashing or writing anything') { opts[:dry_run] = true }
        o.on('--no-keep-awake', 'Let the Mac sleep during this run (default: caffeinate keeps it awake)') { opts[:keep_awake] = false }
      end.parse!(args)
      raise Error, "scrub takes drive NAMEs or --all, not both\n\n#{USAGE}" if opts[:all] && args.any?
      raise Error, '--jobs must be a positive integer' unless opts[:jobs].is_a?(Integer) && opts[:jobs].positive?

      deadline = opts[:for] ? @clock.now + parse_duration(opts[:for]) : nil
      targets = resolve_scrub_targets(args, all: opts[:all])
      raise Error, 'no mounted, non-retired drive to scrub' if targets.empty?

      results = []
      lock = Jbod::RunLock.new(settings[:lock_path])
      lock.acquire(kind: 'scrub') do
        log = Jbod::RunLog.open(settings[:log_dir], keep: settings[:keep_logs], out: @out, clock: @clock, prefix: 'scrub')
        begin
          log.puts "easy_sync #{VERSION} scrub · #{@clock.now.strftime('%Y-%m-%d %H:%M:%S %Z')}" \
                   "#{' · DRY RUN' if opts[:dry_run]}#{" · jobs #{opts[:jobs]}" if opts[:jobs] > 1} · log #{log.path}"
          log.puts 'Keeping the Mac awake for this run (caffeinate).' if opts[:keep_awake] && @keep_awake.start
          pool = Jbod::ScrubPool.new(jobs: opts[:jobs], open_manifest: -> { Jbod::Manifest.open(settings[:manifest_path]) },
                                     scrubber_options: { excludes: settings[:exclude_folders], dry_run: opts[:dry_run] },
                                     lock: lock, clock: @clock, deadline: deadline, out: log)
          results = pool.run(targets)
          stopped = results.select(&:stopped_reason).map do |r|
            "#{r.drive} #{r.stopped_reason == :deadline ? 'hit the --for deadline' : 'was unmounted'}"
          end
          if stopped.empty?
            log.puts 'Scrub finished (ran to completion, not interrupted).'
          else
            log.puts "Scrub stopped early (#{stopped.join('; ')}). Nothing was lost; a later `scrub` resumes it."
          end
        rescue Interrupt
          log.puts 'Scrub interrupted (Ctrl-C) before it finished. Nothing was lost; a later `scrub` resumes it.'
          raise
        ensure
          log.close
        end
      end
      results.any?(&:findings?) ? 1 : 0
    end

    # Named drives, in the order given (an unknown or unmounted name is an
    # error, a retired one is refused); otherwise every mounted, non-retired
    # drive ordered stalest (oldest #scrubbed_through, NULLs/never-scrubbed
    # first) to freshest, trimmed to just the stalest one unless +all+.
    def resolve_scrub_targets(names, all:)
      mounted_by_serial = volume_info.mounted_drives(manifest.drives).to_h { |m| [m.serial_number, m] }
      if names.any?
        names.map do |name|
          drive = manifest.drive_by_name(name) or raise Error, "no drive named #{name}"
          raise Error, "#{name} is retired" if drive.retired?

          mounted_by_serial[drive.serial_number] or raise Error, "#{name} is not mounted"
        end
      else
        stalest = manifest.drives.select { |d| mounted_by_serial.key?(d.serial_number) }
                          .sort_by { |d| [manifest.scrubbed_through(d.serial_number) || '', d.friendly_name] }
                          .map { |d| mounted_by_serial[d.serial_number] }
        all ? stalest : stalest.first(1)
      end
    end

    DEFAULT_BENCHMARK_SIZE = '8gb' # what docs/performance.md's baseline numbers were measured with

    # Writes a test file to each drive, reads it back, deletes it, and keeps
    # the result (the last Manifest::BENCHMARKS_KEPT per drive), so a drive
    # that is slowing down stands out against its own history. One drive at a
    # time: drives measured together would share the enclosure and skew each
    # other. Exits 1 if a drive failed or came out well below its own median.
    def benchmark(args)
      opts = { all: false, history: false, size: DEFAULT_BENCHMARK_SIZE }
      OptionParser.new do |o|
        o.on('--all', 'Benchmark every mounted, non-retired drive, one at a time') { opts[:all] = true }
        o.on('--size SIZE', "Test file size (default #{DEFAULT_BENCHMARK_SIZE}; the drive needs this much free plus the reserve)") do |v|
          opts[:size] = v
        end
        o.on('--history', 'List the kept runs instead of running a new one') { opts[:history] = true }
      end.parse!(args)
      raise Error, "benchmark takes drive NAMEs or --all, not both\n\n#{USAGE}" if opts[:all] && args.any?
      return benchmark_history(args) if opts[:history]

      size = Jbod::Placement.parse_size(opts[:size])
      raise Error, "invalid --size #{opts[:size].inspect}" unless size&.positive?

      targets = resolve_benchmark_targets(args, all: opts[:all])
      raise Error, 'no mounted, non-retired drive to benchmark' if targets.empty?

      ok = true
      lock = Jbod::RunLock.new(settings[:lock_path])
      lock.acquire(kind: 'benchmark') do
        @out.puts 'Keeping the Mac awake for this run (caffeinate).' if settings.fetch(:keep_awake, true) && @keep_awake.start
        benchmarker = Jbod::Benchmarker.new
        targets.each do |m|
          lock.note(m.friendly_name)
          ok = benchmark_drive(benchmarker, m, size) && ok
        end
      end
      ok ? 0 : 1
    end

    # Named drives, in the order given; otherwise every mounted, non-retired
    # drive, the one benchmarked longest ago (never, first) leading, trimmed
    # to just that one unless +all+. Mirrors #resolve_scrub_targets.
    def resolve_benchmark_targets(names, all:)
      mounted_by_serial = volume_info.mounted_drives(manifest.drives).to_h { |m| [m.serial_number, m] }
      if names.any?
        names.map do |name|
          drive = manifest.drive_by_name(name) or raise Error, "no drive named #{name}"
          raise Error, "#{name} is retired" if drive.retired?

          mounted_by_serial[drive.serial_number] or raise Error, "#{name} is not mounted"
        end
      else
        oldest = manifest.drives.select { |d| mounted_by_serial.key?(d.serial_number) }
                        .sort_by { |d| [manifest.last_benchmarked_at(d.serial_number) || '', d.friendly_name] }
                        .map { |d| mounted_by_serial[d.serial_number] }
        all ? oldest : oldest.first(1)
      end
    end

    # Returns false when the drive failed or came out slower than usual; a
    # drive without room for the test file is skipped, which is not a failure.
    def benchmark_drive(benchmarker, mounted, size)
      name = mounted.friendly_name
      reserve = settings.fetch(:reserve_bytes, 0)
      if mounted.free_bytes.to_i < size + reserve
        @out.puts "#{name}: skipped, only #{bytes(mounted.free_bytes)} free; the test file needs #{bytes(size)} " \
                  "plus the #{bytes(reserve)} reserve (a smaller --size fits)"
        return true
      end

      @out.puts "#{name}: writing #{bytes(size)}, then reading it back..."
      result = benchmarker.run(mounted, size: size)
      unless result.ok?
        @out.puts "  FAILED: #{result.error}"
        return false
      end

      earlier = manifest.benchmarks(mounted.serial_number)
      manifest.record_benchmark(mounted.serial_number, bytes: size, write_mb_s: result.write_mb_s.round(1),
                                                       read_mb_s: result.read_mb_s.round(1), used_bytes: result.used_bytes,
                                                       at: @clock.now.utc.iso8601)
      report_benchmark(result, Jbod::Benchmarker.compare(earlier))
    end

    def report_benchmark(result, cmp)
      @out.puts "  write #{mb_s(result.write_mb_s)}, read #{mb_s(result.read_mb_s)} (drive #{bytes(result.used_bytes)} used)"
      if [result.write_mb_s, result.read_mb_s].max > 1000
        @out.puts '  Over 1 GB/s: an SSD, or the page cache was measured instead of the drive (see docs/performance.md).'
      end
      if cmp.earlier.zero?
        @out.puts '  First run for this drive; later runs are compared against it.'
        return true
      end

      @out.puts "  vs. median of #{cmp.earlier} earlier run#{'s' if cmp.earlier != 1}: " \
                "write #{mb_s(cmp.write_median)} (#{signed_pct(cmp.write_change(result.write_mb_s))}), " \
                "read #{mb_s(cmp.read_median)} (#{signed_pct(cmp.read_change(result.read_mb_s))})" \
                "#{" - a slowdown is only flagged from #{Jbod::Benchmarker::MIN_HISTORY} earlier runs on" unless cmp.enough?}"
      slower = cmp.slower(result.write_mb_s, result.read_mb_s)
      return true if slower.empty?

      @out.puts "  SLOWER than usual (#{slower.join(' and ')}). Runs normally vary by about 7%; re-run to confirm. " \
                'A drive that has filled up since writes to slower inner tracks; otherwise this can be an early ' \
                'failure sign SMART does not show yet - check `status`.'
      false
    end

    def benchmark_history(names)
      drives = names.any? ? names.map { |n| manifest.drive_by_name(n) or raise Error, "no drive named #{n}" } : manifest.drives
      drives.each_with_index do |d, i|
        runs = manifest.benchmarks(d.serial_number)
        @out.puts if i.positive?
        @out.puts "#{d.friendly_name}#{runs.empty? ? ': never benchmarked' : " (#{runs.size} run#{'s' if runs.size != 1}, newest first):"}"
        next if runs.empty?

        print_table(%w[WHEN WRITE READ SIZE USED],
                    runs.map { |r| [local_time(r.run_at, '%Y-%m-%d %H:%M'), mb_s(r.write_mb_s), mb_s(r.read_mb_s), bytes(r.bytes), bytes(r.used_bytes)] },
                    right: [1, 2, 3, 4])
      end
      0
    end

    def mb_s(value) = "#{format('%.1f', value)} MB/s"
    def signed_pct(fraction) = fraction ? format('%+d%%', (fraction * 100).round) : '?'

    def parse_duration(spec)
      m = spec.match(/\A(\d+)([mhd])\z/) or raise Error, "invalid --for duration #{spec.inspect} (use e.g. 90m, 8h, 2d)"

      m[1].to_i * { 'm' => 60, 'h' => 3600, 'd' => 86_400 }.fetch(m[2])
    end

    def pending
      rows = manifest.pending_deletions
      if rows.empty?
        @out.puts 'Nothing is pending deletion.'
        return
      end
      now = Time.now
      @out.puts "#{rows.size} pending (deleted after #{settings[:grace_days]} days and #{settings[:grace_runs]} runs missing, " \
                'or once a reassigned folder is verified synced to its new drive):'
      rows.each do |p|
        label = p.whole_folder? ? "#{p.folder_path} (whole folder)" : "#{p.folder_path}/#{p.relative_path}"
        @out.puts "  #{label.ljust(50)} since #{p.first_missing_at}  #{pending_state(p, now)}"
      end
    end

    def pending_state(p, now)
      grace_days, grace_runs = settings[:grace_days], settings[:grace_runs]
      expired = p.expired?(now: now, grace_days: grace_days, grace_runs: grace_runs)

      unless p.reassigned?
        return expired ? 'EXPIRED, deleted on next sync' : "expires #{p.expires_at(grace_days).strftime('%Y-%m-%d')}, seen missing #{p.missing_runs}x"
      end

      old_drive = manifest.drive(p.drive_serial)&.friendly_name || p.drive_serial
      synced = manifest.folder(p.folder_path)&.last_sync_status == 'ok'
      if expired && synced
        'EXPIRED, deleted on next sync'
      elsif synced
        "verified on its new drive; old copy on #{old_drive} goes on #{p.expires_at(grace_days).strftime('%Y-%m-%d')}"
      else
        "old copy on #{old_drive}; waiting for a verified sync to its new drive before this can be deleted"
      end
    end

    # Adds a share. Without --split/--whole the setting is inferred: loose
    # files at the top level force whole; otherwise, if a drive is registered
    # the planner's rule decides, else split (safe for any size; `plan --apply`
    # refines it once drives exist).
    def add_source(args)
      opts = {}
      OptionParser.new do |o|
        o.on('--split', 'Place each subfolder on its own (for shares bigger than one drive)') { opts[:split] = true }
        o.on('--whole', 'Place the whole share as one unit on one drive') { opts[:split] = false }
      end.parse!(args)
      path = args.first or raise Error, "add-source needs the share's path, e.g. /Volumes/tv\n\n#{USAGE}"
      path = File.expand_path(path)
      raise Error, "#{path} is not mounted (or is empty)" unless Dir.exist?(path) && !Dir.empty?(path)

      split, why = opts.key?(:split) ? [opts[:split], 'as you asked'] : infer_split(path)
      config.add_source(path, split: split)
      config.save
      @out.puts "Added #{path} (split: #{split}, #{why}). Config: #{config.path}"
      @out.puts 'Run `easy_sync plan` after registering your drives to check the split settings.' unless opts.key?(:split)
    end

    def infer_split(path)
      excluded = settings[:exclude_folders]
      children = Dir.children(path).reject { |n| n.start_with?('.') || excluded.any? { |pat| File.fnmatch?(pat, n) } }
      loose = children.count { |n| File.file?(File.join(path, n)) }
      dirs = children.count { |n| File.directory?(File.join(path, n)) }
      return [false, "#{loose} loose file#{'s' if loose != 1} at the top level; only a whole share backs those up"] if loose.positive?
      return [false, 'no subfolders to split by'] if dirs.zero?

      largest = manifest.drives.map(&:capacity_bytes).max
      return [true, 'no drive registered yet, so split, which works for any size; `plan --apply` will refine it'] unless largest

      # A drive to judge against: measure the share (du) and apply the planner's rule.
      row = Jbod::Planner.new(settings.merge(sources: [{ path: path, split: true }]), shell: @shell,
                                                                                    largest_drive_bytes: largest).rows.first
      [row.recommend_split, row.reason]
    end

    def remove_source(args)
      path = args.first or raise Error, "remove-source needs the share's path\n\n#{USAGE}"
      config.remove_source(File.expand_path(path))
      config.save
      @out.puts "Removed #{File.expand_path(path)}. Nothing on the drives was touched; folders already placed stay " \
                'in the manifest (they will be reported as missing on the NAS and follow the deletion grace period).'
    end

    def list_sources
      entries = config.source_entries
      if entries.empty?
        @out.puts "No sources configured. Add one with: easy_sync add-source /Volumes/<share>"
        return
      end
      entries.each do |e|
        state = Dir.exist?(e[:path]) && !Dir.empty?(e[:path]) ? 'mounted' : 'NOT MOUNTED'
        @out.puts "  #{e[:path].ljust(32)} #{(e[:split] ? 'split' : 'whole').ljust(6)} #{state}"
      end
    end

    # Measures every configured share and says whether to split it.
    def plan(args)
      opts = {}
      OptionParser.new do |o|
        o.on('--largest-drive SIZE', 'Capacity of the biggest drive you will register, e.g. 8tb (default: from the manifest)') do |v|
          opts[:largest] = Jbod::Placement.parse_size(v)
        end
        o.on('--apply', 'Write the recommended split settings to the config') { opts[:apply] = true }
      end.parse!(args)
      only = args.empty? ? nil : args
      largest = opts[:largest] || manifest.drives.map(&:capacity_bytes).max
      @out.puts(largest ? "Judging against the largest drive: #{Jbod::Placement.format_bytes(largest)}" \
                        : 'No drives registered yet; pass --largest-drive 8tb for recommendations')
      rows = Jbod::Planner.new(settings, shell: @shell, largest_drive_bytes: largest).rows(only: only)
      raise Error, "no configured source matches #{only.join(', ')}" if only && rows.empty?

      rows.each do |r|
        @out.puts "\n#{r.source.path}"
        unless r.mounted
          @out.puts "  #{r.reason}"
          next
        end
        @out.puts "  #{Jbod::Placement.format_bytes(r.size_bytes)} in #{r.subfolders} folder#{'s' if r.subfolders != 1}" \
                  "#{r.largest_name ? ", largest #{r.largest_name} (#{Jbod::Placement.format_bytes(r.largest_subfolder)})" : ''}" \
                  "#{r.loose_files.positive? ? ", #{r.loose_files} loose file#{'s' if r.loose_files != 1}" : ''}"
        @out.puts "  currently split: #{r.source.split}"
        @out.puts "  recommend split: #{r.recommend_split.nil? ? '?' : r.recommend_split}  (#{r.reason})"
        @out.puts '  -> CHANGE the config to match' if r.mismatch?
      end
      changes = rows.select(&:mismatch?)
      if opts[:apply]
        changes.each { |r| config.set_split(r.source.path, r.recommend_split) }
        config.save if changes.any?
        @out.puts(changes.empty? ? "\nConfig already matches the recommendations." \
                                 : "\nUpdated #{changes.size} source#{'s' if changes.size != 1} in #{config.path}.")
      elsif changes.any?
        suggestion = (['easy_sync plan'] + Array(only) + ['--apply']).join(' ')
        @out.puts "\nRun `#{suggestion}` to write these recommendations to the config."
      end
    end

    def register_drive(args)
      opts = {}
      OptionParser.new do |o|
        o.on('--name NAME', 'Friendly name, e.g. backup-04-8tb (defaults to the volume name)') { |v| opts[:name] = v }
        o.on('--serial SERIAL', 'Serial to use, skipping auto-detection (default: smartctl, falling back to the APFS Volume UUID)') { |v| opts[:serial] = v }
      end.parse!(args)
      mount_point = args.first or raise Error, "register-drive needs a mount point\n\n#{USAGE}"
      raise Error, "#{mount_point} is not mounted" unless Dir.exist?(mount_point)

      existing = volume_info.read_marker(mount_point)
      raise Error, "#{mount_point} already carries a marker for #{existing[:serial_number]} (#{existing[:friendly_name]})" if existing

      name = opts[:name] || File.basename(mount_point)
      uuid = volume_info.volume_uuid(mount_point)
      serial, source = resolve_serial(opts[:serial], mount_point, uuid)
      serial or raise Error, 'could not determine a serial via smartctl or diskutil; pass --serial'
      @out.puts "Using #{source} as the serial number." unless opts[:serial]
      usage = volume_info.usage(mount_point)
      model = volume_info.smartctl_model(mount_point)

      drive = manifest.register_drive(serial_number: serial, friendly_name: name, model: model,
                                      capacity_bytes: usage.capacity_bytes, volume_uuid: uuid)
      manifest.update_drive_usage(serial, used_bytes: usage.used_bytes, free_bytes: usage.free_bytes)
      health = volume_info.smart_health(mount_point)
      manifest.update_drive_health(serial, status: health.status, detail: health.detail)
      volume_info.write_marker(mount_point, serial_number: serial, friendly_name: name)
      @out.puts "Registered #{drive.friendly_name} (#{drive.serial_number}#{drive.branded_model ? ", #{drive.branded_model}" : ''}), " \
                "#{Jbod::Placement.format_bytes(drive.capacity_bytes)} at #{mount_point}"
      @out.puts "SMART: #{health.status} (#{health.detail})"
    end

    # Retires OLD. With --to NEW every folder on OLD is recorded as living on
    # NEW; without it the folders are forgotten so the next sync places them
    # afresh across whatever is mounted. --copy first rsyncs OLD's contents to
    # NEW over the local bus (both must be mounted), so a readable old drive
    # never has to be re-pulled from the NAS.
    def replace_drive(args)
      opts = { copy: false }
      OptionParser.new do |o|
        o.on('--to NEW_NAME', 'Registered drive that takes over every folder of the old one') { |v| opts[:to] = v }
        o.on('--copy', 'Copy the old drive onto the new one locally first (both mounted)') { opts[:copy] = true }
        o.on('--note TEXT') { |v| opts[:note] = v }
      end.parse!(args)
      old_name = args.first or raise Error, "replace-drive needs the old drive's name\n\n#{USAGE}"
      old = manifest.drive_by_name(old_name) or raise Error, "no drive named #{old_name}"
      raise Error, "#{old_name} is already retired" if old.retired?

      new_drive = nil
      if opts[:to]
        new_drive = manifest.drive_by_name(opts[:to]) or raise Error, "no drive named #{opts[:to]}; register it first"
        raise Error, "#{opts[:to]} is retired" if new_drive.retired?
        raise Error, 'old and new drive are the same' if new_drive.serial_number == old.serial_number
      end
      raise Error, '--copy needs --to NEW_NAME' if opts[:copy] && !new_drive

      folders = manifest.folders_on(old.serial_number)
      copy_drive(old, new_drive) if opts[:copy]

      note = opts[:note] || (new_drive ? "#{old.friendly_name} replaced by #{new_drive.friendly_name}" : "#{old.friendly_name} retired")
      manifest.move_all_folders(old.serial_number, new_drive&.serial_number, note: note)
      manifest.retire_drive(old.serial_number)

      @out.puts "Retired #{old.friendly_name}."
      if new_drive
        @out.puts "#{folders.size} folder#{'s' if folders.size != 1} now recorded on #{new_drive.friendly_name}."
        @out.puts(opts[:copy] ? 'Run `easy_sync sync` to verify them against the NAS.' \
                              : 'Run `easy_sync sync` to copy them there from the NAS.')
      else
        @out.puts "#{folders.size} folder#{'s' if folders.size != 1} forgotten; the next `easy_sync sync` will place " \
                  'them afresh across the mounted drives and copy them from the NAS.'
      end
    end

    # rsync OLD -> NEW over the local bus, excluding each drive's own .easy_sync folder.
    def copy_drive(old, new_drive)
      mounted = volume_info.mounted_drives([old, new_drive]).to_h { |m| [m.serial_number, m] }
      src = mounted[old.serial_number] or raise Error, "#{old.friendly_name} is not mounted (needed for --copy)"
      dst = mounted[new_drive.serial_number] or raise Error, "#{new_drive.friendly_name} is not mounted (needed for --copy)"
      if src.used_bytes > dst.free_bytes
        raise Error, "#{new_drive.friendly_name} has #{Jbod::Placement.format_bytes(dst.free_bytes)} free but " \
                     "#{old.friendly_name} holds #{Jbod::Placement.format_bytes(src.used_bytes)}"
      end
      @out.puts "Copying #{old.friendly_name} -> #{new_drive.friendly_name} (#{Jbod::Placement.format_bytes(src.used_bytes)})..."
      excludes = (settings[:exclude_folders] + [Jbod::DRIVE_DIR]).map { |e| "--exclude=#{e}" }
      result = @shell.run(['rsync', '-a', '--partial', '--stats', '--info=progress2', *excludes, "#{src.mount_point}/", "#{dst.mount_point}/"])
      raise Error, "copy failed (rsync exit #{result.status}); nothing was changed in the manifest" unless result.success?
    end

    # The reverse of `sync`: copies folders from their drives back onto the
    # NAS. Never deletes anything already on the NAS. A dry run only reads
    # (rsync --dry-run plus no directory creation), so it may run alongside a
    # sync; a real restore takes the same lock a sync does.
    def restore(args)
      opts = { dry_run: false, all: false }
      OptionParser.new do |o|
        o.on('--dry-run', 'Show what would be restored without changing the NAS') { opts[:dry_run] = true }
        o.on('--all', 'Restore every folder in the manifest') { opts[:all] = true }
      end.parse!(args)
      raise Error, "restore needs a folder or share name (e.g. tv or \"tv/Show Name\"), or --all\n\n#{USAGE}" if args.empty? && !opts[:all]

      restorer = Jbod::Restorer.new(settings, manifest: manifest, shell: @shell, out: @out)
      folders = opts[:all] ? manifest.folders : restorer.resolve(args)
      raise Error, 'nothing to restore' if folders.empty?

      lock = opts[:dry_run] ? ->(**, &blk) { blk.call } : Jbod::RunLock.new(settings[:lock_path]).method(:acquire)
      result = nil
      lock.call(kind: 'restore') { result = restorer.run(folders, volume_info.mounted_drives(manifest.drives), dry_run: opts[:dry_run]) }
      @out.puts "\n#{opts[:dry_run] ? 'Would restore' : 'Restored'} #{result.restored.size}, " \
                "skipped #{result.skipped.size}, failed #{result.failed.size}"
    end

    # --serial wins outright. Otherwise try the hardware serial via smartctl
    # first (a real, stable serial that survives a reformat), falling back to
    # the APFS Volume UUID when smartctl can't reach the drive (no smartctl
    # installed, needs elevated privileges, or - common for external USB
    # enclosures - the bridge chip doesn't pass SMART through at all).
    def resolve_serial(explicit, mount_point, uuid)
      return [explicit, 'the --serial you gave'] if explicit

      if (serial = volume_info.smartctl_serial(mount_point))
        [serial, 'the smartctl hardware serial']
      else
        [uuid, 'the diskutil Volume UUID (smartctl serial unavailable)']
      end
    end

    def status(args)
      all = false
      OptionParser.new { |o| o.on('--all', 'List every placed folder, one per line (for piping)') { all = true } }.parse!(args)
      run = Jbod::RunLock.new(settings[:lock_path]).status
      print_run_status(run)
      print_drives(all)
      all ? print_all_folders : print_folder_summary
      print_scrub_status(run)
    end

    # A drive is overdue once it's gone scrub_stale_days without a full
    # check (or never had one) and actually has something synced to it - an
    # empty new drive is not overdue. Alongside that, the fleet-wide count of
    # rows scrub has flagged as corrupt/unreadable/unresolved.
    def print_scrub_status(run)
      active = run&.kind == 'scrub' ? run.current : []
      overdue = manifest.drives.select { |d| scrub_overdue?(d) && !active.include?(d.friendly_name) }
      unless overdue.empty?
        @out.puts "\nOverdue for `scrub`:"
        overdue.each do |d|
          through = manifest.scrubbed_through(d.serial_number)
          label = through ? "scrubbed #{days_ago(through)} days ago" : 'never scrubbed'
          @out.puts "  #{d.friendly_name.ljust(16)} #{label}"
        end
      end
      print_scrubbing_progress(run) unless active.empty?
      findings = manifest.scrub_findings.size
      return unless findings.positive?

      @out.puts "\n#{findings} file#{'s' if findings != 1} flagged by scrub (corrupt, unreadable, or unresolved); " \
                'run `easy_sync scrub` to work through them.'
    end

    # How far each currently-scrubbing drive has gotten through this run:
    # files verified since the run started, not files ever hashed (a drive
    # scrubbed before already has an old digest for nearly everything, which
    # would misleadingly read as "done" the instant this run started). This
    # is the *only* place a currently-scrubbing drive is listed - #overdue
    # above excludes it, so a drive never appears in both sections at once.
    def print_scrubbing_progress(run)
      @out.puts "\nScrubbing now:"
      run.current.each do |name|
        drive = manifest.drive_by_name(name)
        progress = drive && manifest.checksum_progress(drive.serial_number, since: run.started_at.utc.iso8601)
        label = if progress.nil? || progress[:total].zero?
                  'scrubbing now'
                else
                  pct = ((100.0 * progress[:checked]) / progress[:total]).round
                  "#{progress[:checked]}/#{progress[:total]} files checked (#{pct}%)"
                end
        @out.puts "  #{name.ljust(16)} #{label}"
      end
    end

    def scrub_overdue?(drive)
      return false unless manifest.folders_on(drive.serial_number).any?(&:last_synced_at)

      through = manifest.scrubbed_through(drive.serial_number)
      through.nil? || Time.parse(through) < (@clock.now - (settings[:scrub_stale_days] * 86_400))
    end

    def days_ago(iso)
      ((@clock.now - Time.parse(iso)) / 86_400).floor
    end

    RETIRED_SHOWN = 5   # most recent; older ones are still in the manifest, just not printed by default

    def print_drives(all = false)
      drives = manifest.drives
      mounted = volume_info.mounted_drives(drives).to_h { |m| [m.serial_number, m] }
      @out.puts 'Drives:'
      unless drives.empty?
        rows = drives.map do |d|
          m = mounted[d.serial_number]
          [d.friendly_name, d.branded_model ? "#{d.serial_number} · #{d.branded_model}" : d.serial_number,
           m ? Jbod::Placement.format_bytes(m.free_bytes) : '—',
           m ? Jbod::Placement.format_bytes(m.used_bytes) : '—',
           smart_summary(d), drive_note(d, m)]
        end
        print_table(%w[DRIVE SERIAL FREE USED SMART] + [''], rows, right: [2, 3])
        total_capacity = drives.sum(&:capacity_bytes)
        total_free = drives.sum { |d| (mounted[d.serial_number]&.free_bytes || d.last_free_bytes).to_i }
        @out.puts
        @out.puts "Total: #{bytes(total_capacity)} capacity, #{bytes(total_free)} free right now"
      end
      retired = manifest.drives(include_retired: true).select(&:retired?).sort_by(&:retired_at).reverse
      return if retired.empty?

      shown = all ? retired : retired.first(RETIRED_SHOWN)
      hidden = retired.size - shown.size
      line = "  Retired: #{shown.map { |d| "#{d.friendly_name} (#{local_time(d.retired_at, '%Y-%m-%d')})" }.join(', ')}"
      line += " · #{hidden} more (see `status --all`)" if hidden.positive?
      @out.puts if drives.any?
      @out.puts line
    end

    def print_table(header, rows, right: [])
      all = [header] + rows
      widths = header.each_index.map { |i| all.map { |r| r[i].to_s.length }.max }
      all.each do |r|
        cells = r.each_with_index.map { |c, i| right.include?(i) ? c.to_s.rjust(widths[i]) : c.to_s.ljust(widths[i]) }
        @out.puts "  #{cells.join('  ')}".rstrip
      end
    end

    SMART_STATUS_LABELS = { 'degraded_stable' => 'stable wear' }.freeze

    # The verdict plus only what's worth reading: zero counters and the
    # PASSED verdict (implied by ok/warning) are dropped; ok keeps just the temperature.
    def smart_summary(drive)
      return 'unchecked' unless drive.smart_status
      return 'n/a' if drive.smart_status == 'unknown'

      parts = drive.smart_detail.to_s.split(' · ').reject { |p| p == 'PASSED' || p.match?(/\A[a-z ]+ 0\z/) }
      parts = parts.grep(/°C\z/) if drive.smart_status == 'ok'
      [SMART_STATUS_LABELS.fetch(drive.smart_status, drive.smart_status), *parts].join(' · ')
    end

    # Only the unusual: not mounted, locked, or mounted somewhere other than under its own name.
    def drive_note(drive, mounted)
      if mounted
        File.basename(mounted.mount_point) == drive.friendly_name ? '' : "at #{mounted.mount_point}"
      elsif volume_info.locked?(drive.friendly_name)
        "connected but LOCKED (unlock it: diskutil apfs unlockVolume #{drive.friendly_name})"
      else
        "not mounted (last seen #{drive.last_seen_at ? local_time(drive.last_seen_at, '%Y-%m-%d %H:%M') : 'never'})"
      end
    end

    def local_time(iso, format)
      Time.parse(iso).localtime.strftime(format)
    rescue ArgumentError, TypeError
      iso
    end

    # Counts only: how many folders are placed/not backed up/empty, and
    # whether any placed folder's last sync failed. The full per-folder
    # breakdown lives in the dashboard (grouped per drive) or `status --all`.
    def print_folder_summary
      folders = manifest.folders
      inventory = manifest.source_inventory
      @out.puts "\nFolders:"
      if inventory.empty?
        @out.puts "  #{folders.size} placed (#{Jbod::Placement.format_bytes(folders.sum { |f| f.size_bytes.to_i })})"
      else
        unplaced = inventory.select { |e| e.state == 'unplaced' }
        empty = inventory.count { |e| e.state == 'empty' }
        @out.puts "  #{inventory.count { |e| e.state == 'placed' }} placed, " \
                  "#{unplaced.size} not backed up (#{Jbod::Placement.format_bytes(unplaced.sum { |e| e.size_bytes.to_i })}), " \
                  "#{empty} empty"
      end
      failed = folders.count { |f| f.last_sync_status == 'failed' }
      @out.puts "  #{failed} folder#{'s' unless failed == 1} failed their last sync" if failed.positive?
      @out.puts '  (use `status --all` to list every placed folder, or `dashboard` for the full report)'
    end

    def print_all_folders
      names = manifest.drives(include_retired: true).to_h { |d| [d.serial_number, d.friendly_name] }
      folders = manifest.folders
      width = folders.map { |f| f.folder_path.length }.max.to_i
      @out.puts "\nFolders:"
      folders.each do |f|
        @out.puts "  #{f.folder_path.ljust(width)} #{names.fetch(f.drive_serial, f.drive_serial).ljust(16)} " \
                  "#{Jbod::Placement.format_bytes(f.size_bytes).rjust(10)}  last synced #{f.last_synced_at || 'never'} " \
                  "#{f.last_sync_status}"
      end
    end

    # A stale lock (its process no longer running) is reported as not running,
    # the same way RunLock itself would reclaim it on the next `sync`. The
    # lock is shared by sync/scrub/clean/restore (RunLock#kind), so this must
    # say which one is actually running rather than assuming sync - the ETA
    # estimate below is sync-specific and only makes sense for a real sync.
    def print_run_status(run)
      if run
        line = "#{run.kind.capitalize} running: pid #{run.pid}, started #{run.started_at.strftime('%Y-%m-%d %H:%M:%S %Z')} " \
               "(#{format_elapsed(@clock.now - run.started_at)} ago)"
        line += " on #{run.current.join(', ')}" if run.kind == 'scrub' && run.current.any?
        @out.puts line
        if run.kind == 'sync'
          eta = sync_eta(run.started_at)
          @out.puts eta if eta
        end
      else
        @out.puts 'No sync currently running.'
      end
      @out.puts
    end

    def format_elapsed(seconds) = Jbod::Placement.format_duration(seconds)

    # Formats a Jbod::SyncEta::Estimate as the one-line message `status` shows
    # under the running-sync line.
    def sync_eta(started_at)
      e = Jbod::SyncEta.for(manifest, started_at)
      case e&.status
      when nil then nil
      when :waiting_for_first_folder
        '  Estimating time remaining: still measuring/placing folders, or waiting on a large first copy to finish...'
      when :waiting_for_first_transfer
        "  #{e.never_synced_count} folder#{'s' if e.never_synced_count != 1} never synced (#{bytes(e.never_synced_bytes)}); " \
          'still waiting for one to finish before estimating their time.'
      when :estimate
        "  About #{format_elapsed(e.seconds)} remaining (#{e.never_synced_count} folder#{'s' if e.never_synced_count != 1} never synced, " \
          "#{e.to_reverify} to re-verify) - rough estimate, NAS/network speed varies."
      end
    end

    def bytes(value) = Jbod::Placement.format_bytes(value)

    def history(folder)
      names = manifest.drives(include_retired: true).to_h { |d| [d.serial_number, d.friendly_name] }
      manifest.history(folder).each do |e|
        @out.puts "#{e.recorded_at}  #{e.event.ljust(10)} #{e.folder_path.ljust(30)} -> #{names.fetch(e.drive_serial, e.drive_serial)}  #{e.note}"
      end
    end

    def reassign(args)
      opts = { force: false }
      OptionParser.new do |o|
        o.on('--note TEXT') { |v| opts[:note] = v }
        o.on('--force', 'Reassign even though the target drive does not appear to have room') { opts[:force] = true }
      end.parse!(args)
      folder, drive_name = args
      raise Error, "reassign needs FOLDER and DRIVE_NAME\n\n#{USAGE}" unless folder && drive_name

      drive = manifest.drive_by_name(drive_name) or raise Error, "no drive named #{drive_name}"
      record = manifest.folder(folder) or raise Error, "#{folder} is not in the manifest"
      check_fits!(record, drive) unless opts[:force]

      manifest.reassign_folder(folder, drive.serial_number, note: opts[:note])
      @out.puts "#{folder} is now recorded on #{drive.friendly_name}. No data was moved."
    end

    # Same free-space accounting `sync` uses to place new folders: whichever
    # is smaller of live free space and (capacity minus everything already
    # promised to that drive), so reassign can't blindly send a folder
    # somewhere it won't fit either (see the backup-06-8tb overcommit this
    # was built to stop happening again).
    def check_fits!(record, drive)
      return unless record.size_bytes

      mounted = volume_info.mounted_drives([drive]).first
      unless mounted
        @out.puts "#{drive.friendly_name} is not mounted; couldn't check whether it has room."
        return
      end
      promised = manifest.folders_on(drive.serial_number).sum { |f| f.size_bytes.to_i }
      free = [mounted.free_bytes.to_i, drive.capacity_bytes.to_i - promised].min
      reserve = settings.fetch(:reserve_bytes, 0)
      return unless (free - reserve) < record.size_bytes

      raise Error, "#{record.folder_path} (#{Jbod::Placement.format_bytes(record.size_bytes)}) does not fit on " \
                   "#{drive.friendly_name} (#{Jbod::Placement.format_bytes(free)} free, " \
                   "#{Jbod::Placement.format_bytes(reserve)} reserved). Use --force to reassign anyway."
    end

    # Only relabels the manifest (and the drive's own marker); the tool never
    # renames the actual macOS volume itself, the same way it never unlocks
    # one. friendly_name is UNIQUE, so a name already taken by another
    # registered drive is treated as "swap these two", not an error.
    def rename_drive(args)
      old_name, new_name = args
      raise Error, "rename-drive needs OLD_NAME and NEW_NAME\n\n#{USAGE}" unless old_name && new_name
      raise Error, 'old and new name are the same' if old_name == new_name

      old = manifest.drive_by_name(old_name) or raise Error, "no drive named #{old_name}"
      raise Error, "#{old_name} is retired" if old.retired?
      target = manifest.drive_by_name(new_name)
      mounted = volume_info.mounted_drives(manifest.drives).to_h { |m| [m.serial_number, m] }

      if target
        manifest.swap_drive_names(old.serial_number, target.serial_number)
        @out.puts "Swapped names: #{old_name} <-> #{new_name}."
        relabel_marker(old.serial_number, new_name, mounted)
        relabel_marker(target.serial_number, old_name, mounted)
        rename_volume_hint(old.serial_number, new_name, mounted)
        rename_volume_hint(target.serial_number, old_name, mounted)
      else
        manifest.rename_drive(old.serial_number, new_name)
        @out.puts "Renamed #{old_name} to #{new_name}."
        relabel_marker(old.serial_number, new_name, mounted)
        rename_volume_hint(old.serial_number, new_name, mounted)
      end
    end

    # Manually confirms that a drive flagged 'warning' or 'degraded_stable'
    # over reallocated sectors is not actively getting worse - typically
    # after an independent full-surface scan (SpinRite etc.) found zero new
    # defects. Locks in the drive's most recently read reallocated-sector
    # count as the new baseline, so future checks compare against today,
    # not against whatever the count happened to be before this tool ever
    # tracked it.
    def verify_drive(args)
      opts = {}
      OptionParser.new { |o| o.on('--note TEXT', 'e.g. "SpinRite Level 3, 22.5h, 0 new defects"') { |v| opts[:note] = v } }.parse!(args)
      name = args.first or raise Error, "verify-drive needs a drive name\n\n#{USAGE}"
      drive = manifest.drive_by_name(name) or raise Error, "no drive named #{name}"

      manifest.verify_drive_stable(drive.serial_number, note: opts[:note])
      if drive.smart_status == 'warning'
        manifest.update_drive_health(drive.serial_number, status: 'degraded_stable', detail: drive.smart_detail)
      end
      message = "Recorded #{name}'s current reallocated-sector count as a verified-stable checkpoint."
      message += " Note: #{opts[:note]}" if opts[:note]
      @out.puts message
    end

    # Keeps the drive's own .easy_sync/drive.json readable-by-hand, though
    # nothing reads its friendly_name back: matching is by serial only.
    def relabel_marker(serial, new_name, mounted)
      m = mounted[serial] or return
      existing = volume_info.read_marker(m.mount_point)
      registered_at = existing&.fetch(:registered_at, nil) || Time.now.utc.iso8601
      volume_info.write_marker(m.mount_point, serial_number: serial, friendly_name: new_name, registered_at: registered_at)
    end

    def rename_volume_hint(serial, new_name, mounted)
      m = mounted[serial] or return

      @out.puts "  #{m.mount_point} still has its old macOS volume name; to match, rename it yourself: " \
                "diskutil rename #{m.mount_point} #{new_name}"
    end

    def dashboard
      mounted = volume_info.mounted_drives(manifest.drives)
      run = Jbod::RunLock.new(settings[:lock_path]).status
      path = Jbod::Dashboard.new(manifest, grace_days: settings[:grace_days], scrub_stale_days: settings[:scrub_stale_days])
                            .write(settings[:dashboard_path], mounted: mounted, running: run)
      @out.puts "Dashboard written to #{path}"
    end
  end
end
