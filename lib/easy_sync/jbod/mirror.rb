# frozen_string_literal: true

require 'fileutils'

module EasySync
  module Jbod
    # Mirrors one source folder onto one destination folder with rsync.
    class Mirror
      Result = Struct.new(:exit_status, :bytes_transferred, :total_size_bytes, :output, keyword_init: true) do
        def success? = exit_status.zero?
      end

      def initialize(shell: Shell.new, delete: true, extra_args: [])
        @shell = shell
        @delete = delete
        @extra_args = Array(extra_args)
      end

      def command(source, destination)
        argv = ['rsync', '-a', '--stats', '--info=progress2']
        argv << '--delete' if @delete
        argv += @extra_args
        argv + [with_slash(source), with_slash(destination)]
      end

      def sync(source, destination)
        raise Error, "source folder #{source} does not exist" unless Dir.exist?(source)

        FileUtils.mkdir_p(File.dirname(destination))
        result = @shell.run(command(source, destination))
        stats = self.class.parse_stats(result.output)
        Result.new(exit_status: result.status, output: result.output, **stats)
      end

      # Pulls the two numbers we keep out of `rsync --stats` output.
      def self.parse_stats(output)
        {
          total_size_bytes: stat(output, 'Total file size'),
          bytes_transferred: stat(output, 'Total transferred file size')
        }
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
