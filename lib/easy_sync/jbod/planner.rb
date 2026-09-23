# frozen_string_literal: true

module EasySync
  module Jbod
    # `easy_sync plan`: measures each configured share and checks that every
    # top-level folder (each is placed on its own) fits on the largest drive
    # in the fleet. Reads only; never places or copies anything.
    class Planner
      Row = Struct.new(:source, :mounted, :size_bytes, :subfolders, :largest_subfolder, :largest_name, :loose_files,
                       :reason, :fits, keyword_init: true)

      def initialize(settings, shell: Shell.new, largest_drive_bytes: nil)
        @settings = settings
        @shell = shell
        @largest = largest_drive_bytes
      end

      # +only+ restricts to sources whose basename or full path is in the list
      # (e.g. easy_sync plan pro, matching /Volumes/pro). nil measures all.
      def rows(only: nil)
        sources = Array(@settings[:sources]).map { |e| Runner::Source.from_config(e) }
        sources = sources.select { |s| only.include?(s.name) || only.include?(s.path) } if only
        sources.map { |src| measure(src) }
      end

      private

      def measure(source)
        row = Row.new(source: source, mounted: Dir.exist?(source.path) && !Dir.empty?(source.path), loose_files: 0,
                      subfolders: 0)
        return row.tap { |r| r.reason = 'not mounted (or empty)' } unless row.mounted

        excluded = Array(@settings[:exclude_folders])
        children = Dir.children(source.path).sort.reject { |n| excluded.include?(n) || n.start_with?('.') }
        dirs = children.select { |n| File.directory?(File.join(source.path, n)) }
        row.loose_files = children.count { |n| File.file?(File.join(source.path, n)) }
        row.subfolders = dirs.size

        sizes = du(dirs.map { |n| File.join(source.path, n) })
        row.size_bytes = sizes.values.sum
        row.largest_name, row.largest_subfolder = sizes.max_by { |_, v| v } || [nil, 0]
        check_fit(row)
      end

      # One `du -sk` over every subfolder; the tool's own `du` cost was
      # measured at ~6 s for 2,380 movie folders over SMB.
      def du(paths)
        return {} if paths.empty?

        result = @shell.capture(['du', '-sk', *paths])
        result.output.each_line.with_object({}) do |line, h|
          kb, path = line.chomp.split("\t", 2)
          next unless kb && path

          h[File.basename(path.chomp('/'))] = kb.to_i * 1024
        end
      end

      def check_fit(row)
        largest = @largest
        if largest.nil?
          row.reason = 'register a drive (or pass --largest-drive) to check whether every folder fits'
        elsif row.largest_subfolder.to_i > largest
          row.fits = false
          row.reason = "WARNING: #{row.largest_name} alone is #{Placement.format_bytes(row.largest_subfolder)}, " \
                       "bigger than the largest drive currently registered (#{Placement.format_bytes(largest)}); " \
                       'it cannot be placed on this fleet today, but will fit once you add a bigger drive'
        else
          row.fits = true
          row.reason = 'every folder fits on the largest drive'
        end
        row
      end
    end
  end
end
