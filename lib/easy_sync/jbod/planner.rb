# frozen_string_literal: true

module EasySync
  module Jbod
    # `jbod plan`: measures each configured share and recommends whether it
    # should be placed whole (split: false) or one subfolder at a time
    # (split: true), judged against the largest drive in the fleet. Reads
    # only; never places or copies anything.
    class Planner
      Row = Struct.new(:source, :mounted, :size_bytes, :subfolders, :largest_subfolder, :largest_name, :loose_files,
                       :recommend_split, :reason, :fits, keyword_init: true) do
        def mismatch? = mounted && !recommend_split.nil? && recommend_split != source.split
      end

      # Above this fraction of the largest drive a whole share is a bad idea:
      # it fits today but can never move, and the drive fills around it.
      SPLIT_ABOVE = 0.5

      def initialize(settings, shell: Shell.new, largest_drive_bytes: nil)
        @settings = settings
        @shell = shell
        @largest = largest_drive_bytes
      end

      def rows
        Array(@settings[:sources]).map { |e| Runner::Source.from_config(e) }.map { |src| measure(src) }
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
        recommend(row)
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

      def recommend(row)
        largest = @largest
        if row.loose_files.positive?
          row.recommend_split = false
          row.reason = "#{row.loose_files} loose file#{'s' if row.loose_files != 1} at the top level; only a whole " \
                       'share backs those up'
        elsif row.subfolders.zero?
          row.recommend_split = false
          row.reason = 'no subfolders to split by'
        elsif largest.nil?
          row.reason = 'register a drive (or pass --largest-drive) to get a recommendation'
        elsif row.size_bytes > largest
          row.recommend_split = true
          row.reason = "#{Placement.format_bytes(row.size_bytes)} is larger than the largest drive " \
                       "(#{Placement.format_bytes(largest)}); it can only be placed one folder at a time"
        elsif row.size_bytes > largest * SPLIT_ABOVE
          row.recommend_split = true
          row.reason = "#{Placement.format_bytes(row.size_bytes)} is more than half the largest drive; whole it " \
                       'would jam one drive as it grows'
        else
          row.recommend_split = false
          row.reason = "#{Placement.format_bytes(row.size_bytes)} fits comfortably; one folder on one drive is " \
                       'simplest to browse'
        end
        if largest && row.largest_subfolder.to_i > largest
          row.fits = false
          row.reason += ". WARNING: #{row.largest_name} alone is #{Placement.format_bytes(row.largest_subfolder)}, " \
                        "bigger than the largest drive currently registered (#{Placement.format_bytes(largest)}); " \
                        'it cannot be placed on this fleet today, but will fit once you add a bigger drive'
        else
          row.fits = true
        end
        row
      end
    end
  end
end
