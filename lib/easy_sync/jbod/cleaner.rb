# frozen_string_literal: true

require 'fileutils'

module EasySync
  module Jbod
    # `easy_sync clean`: removes from the drives, right away, anything whose
    # name matches exclude_folders. Such entries only exist because they were
    # copied before the exclusion did (or before the exclusion was added), so
    # there is no reason to wait out the deletion grace period for them. Walks
    # only the destinations of placed folders, so a drive's own .easy_sync and
    # anything not managed here is never touched.
    class Cleaner
      Result = Struct.new(:removed, :bytes, :would_remove, keyword_init: true) do
        def initialize(**)
          super
          self.removed ||= []
          self.would_remove ||= []
          self.bytes ||= 0
        end
      end

      def initialize(manifest, excludes:, out: $stdout)
        @manifest = manifest
        @excludes = Array(excludes)
        @out = out
      end

      # +mounted+ are MountedDrive structs. Returns a Result.
      def run(mounted, dry_run: false)
        result = Result.new
        mounted.each do |drive|
          @manifest.folders_on(drive.serial_number).each do |folder|
            base = File.join(drive.mount_point, folder.folder_path)
            next unless Dir.exist?(base)

            matches_under(base).each do |path|
              rel = path.delete_prefix("#{base}/")
              size = size_of(path)
              if dry_run
                @out.puts "  would remove #{folder.folder_path}/#{rel} (#{Placement.format_bytes(size)}) from #{drive.friendly_name}"
                result.would_remove << [folder.folder_path, rel]
              else
                kind = File.directory?(path) ? 'dir' : 'file'
                FileUtils.rm_rf(path)
                @out.puts "  removed #{folder.folder_path}/#{rel} (#{Placement.format_bytes(size)}) from #{drive.friendly_name}"
                result.removed << [folder.folder_path, rel]
                result.bytes += size
                @manifest.record_cleaned(folder_path: folder.folder_path, relative_path: rel, kind: kind,
                                         drive_serial: drive.serial_number)
              end
            end
          end
        end
        # Junk that was already gone from the drive (removed by hand, say) may
        # still have pending rows; those need no grace period either.
        @manifest.forget_pending_matching(@excludes) unless dry_run
        result
      end

      private

      # Deepest matches are not needed: removing a matching directory takes
      # its contents with it, so stop descending at the first match.
      def matches_under(dir)
        found = []
        Dir.each_child(dir) do |name|
          path = File.join(dir, name)
          if excluded?(name)
            found << path
          elsif File.directory?(path) && !File.symlink?(path)
            found.concat(matches_under(path))
          end
        end
        found.sort
      rescue SystemCallError
        found
      end

      def excluded?(name)
        @excludes.any? { |pat| File.fnmatch?(pat, name, File::FNM_DOTMATCH) }
      end

      def size_of(path)
        return File.size(path) unless File.directory?(path)

        Dir.glob(File.join(path, '**', '*'), File::FNM_DOTMATCH).sum { |f| File.file?(f) ? File.size(f) : 0 }
      end

    end
  end
end
