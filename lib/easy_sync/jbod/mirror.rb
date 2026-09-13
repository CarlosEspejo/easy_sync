# frozen_string_literal: true

require 'fileutils'

module EasySync
  module Jbod
    # Mirrors one source folder onto one destination folder with rsync.
    #
    # Nothing is ever deleted by rsync itself: `--delete --max-delete=0` makes
    # rsync copy as usual but only *report* files that no longer exist on the
    # source (as "*deleting path" lines, exit status 25). Those reports feed
    # the grace-period purge in Runner.
    class Mirror
      MAX_DELETE_LIMIT_STATUS = 25
      MIN_VERSION = [3, 0, 0].freeze

      Result = Struct.new(:exit_status, :bytes_transferred, :total_size_bytes, :extraneous, :disk_full, :output,
                          keyword_init: true) do
        def success? = exit_status.zero? || exit_status == MAX_DELETE_LIMIT_STATUS
        def disk_full? = !!disk_full
      end

      def initialize(shell: Shell.new, extra_args: [])
        @shell = shell
        @extra_args = Array(extra_args)
      end

      def command(source, destination)
        argv = ['rsync', '-a', '--stats', '--info=progress2', '--itemize-changes', '--delete', '--max-delete=0']
        argv += @extra_args
        argv + [with_slash(source), with_slash(destination)]
      end

      # Raises unless the rsync on PATH is new enough for --max-delete=0 reporting.
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
        Result.new(exit_status: result.status, output: result.output,
                   extraneous: self.class.parse_extraneous(result.output),
                   disk_full: self.class.disk_full?(result.output), **stats)
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
