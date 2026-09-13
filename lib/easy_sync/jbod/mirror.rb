# frozen_string_literal: true

require 'fileutils'

module EasySync
  module Jbod
    # Mirrors one source folder onto one destination folder with rsync.
    #
    # Nothing is ever deleted by rsync itself. Each folder gets two passes: a
    # copy pass with no deletion flags at all, then a read-only probe
    # (`rsync -n --delete --itemize-changes`) whose "*deleting path" lines say
    # which files on the drive no longer exist on the source. Those feed the
    # grace-period purge in Runner. (`--delete --max-delete=0` looked like a
    # one-pass alternative, but rsync then only prints "N skipped" without
    # naming the files, and exits 25.)
    class Mirror
      MIN_VERSION = [3, 0, 0].freeze

      Result = Struct.new(:exit_status, :bytes_transferred, :total_size_bytes, :extraneous, :disk_full, :output,
                          keyword_init: true) do
        def success? = exit_status.zero?
        def disk_full? = !!disk_full
      end

      # +excludes+ are rsync patterns (no slash, so they match at any depth):
      # the config's exclude_folders. They apply to both passes.
      def initialize(shell: Shell.new, extra_args: [], excludes: [])
        @shell = shell
        @extra_args = Array(extra_args)
        @excludes = Array(excludes).map { |e| "--exclude=#{e}" }
      end

      # The copy pass. Extra args (from config, or --dry-run) apply here.
      def command(source, destination)
        argv = ['rsync', '-a', '--stats', '--info=progress2', '--itemize-changes', *@excludes]
        argv += @extra_args
        argv + [with_slash(source), with_slash(destination)]
      end

      # The deletion probe: never copies, never deletes, only reports.
      # --delete-excluded makes it also report excluded junk that an earlier
      # run copied before the exclusion existed, so the purge clears it.
      def probe_command(source, destination)
        ['rsync', '-an', '--itemize-changes', '--delete', '--delete-excluded', *@excludes,
         with_slash(source), with_slash(destination)]
      end

      # Raises unless the rsync on PATH is new enough for --itemize-changes deletion reporting.
      def self.check_version!(shell)
        result = shell.capture(['rsync', '--version'])
        version = result.output[/rsync\s+version\s+(\d+)\.(\d+)\.(\d+)/, 0]
        raise Error, 'rsync not found on PATH' unless result.success? && version

        numbers = version.scan(/\d+/).map(&:to_i)
        return numbers.join('.') if (numbers <=> MIN_VERSION) >= 0

        raise Error, "rsync #{numbers.join('.')} is too old; 3.0 or newer is required (brew install rsync)"
      rescue Errno::ENOENT
        raise Error, 'rsync not found on PATH'
      end

      def sync(source, destination)
        raise Error, "source folder #{source} does not exist" unless Dir.exist?(source)

        FileUtils.mkdir_p(File.dirname(destination))
        result = @shell.run(command(source, destination))
        stats = self.class.parse_stats(result.output)
        # Only probe after a clean copy: a half-synced folder must not start
        # deletion clocks.
        extraneous = result.success? ? probe(source, destination) : nil
        Result.new(exit_status: result.status, output: result.output, extraneous: extraneous,
                   disk_full: self.class.disk_full?(result.output), **stats)
      end

      # Files present on the drive but gone from the source, as [[path, kind], ...].
      # nil if the probe itself failed, so the caller records nothing.
      def probe(source, destination)
        result = @shell.capture(probe_command(source, destination))
        result.success? ? self.class.parse_extraneous(result.output) : nil
      end

      # True when rsync's own output says the destination ran out of space.
      # Deliberately a text match rather than a specific exit status: rsync
      # reports this the same way (exit 11) as other unrelated I/O errors.
      def self.disk_full?(output)
        output.match?(/No space left on device/i)
      end

      # Pulls the two numbers we keep out of `rsync --stats` output.
      def self.parse_stats(output)
        {
          total_size_bytes: stat(output, 'Total file size'),
          bytes_transferred: stat(output, 'Total transferred file size')
        }
      end

      # "*deleting   some/dir/" and "*deleting   some/file" lines -> [[path, kind], ...]
      def self.parse_extraneous(output)
        output.scan(/^\*deleting\s+(.+?)\r?$/).map do |(path)|
          path.end_with?('/') ? [path.chomp('/'), 'dir'] : [path, 'file']
        end
      end

      def self.stat(output, label)
        match = output[/^#{Regexp.escape(label)}:\s*([\d,.]+)/, 1]
        match && match.delete(',').to_i
      end

      private

      def with_slash(path)
        path.end_with?('/') ? path : "#{path}/"
      end
    end
  end
end
