# frozen_string_literal: true

require 'fileutils'

module EasySync
  module Jbod
    # `easy_sync restore`: the reverse of `sync`. Copies a folder (or every
    # folder under a share, or everything) from wherever the manifest says it
    # currently lives back onto its NAS share. For rebuilding a NAS after a
    # wipe/reformat, the scenario the old single-drive drobo-sync restore
    # scripts covered by hand; here the folders for one share can be spread
    # across several drives, so this walks the manifest instead of assuming
    # one source directory.
    #
    # Never deletes, exactly like those old scripts: only adds and updates
    # files on the NAS. A drive with fewer files than the NAS already has
    # leaves the extra NAS files alone.
    class Restorer
      class UnknownTarget < Error; end

      Result = Struct.new(:restored, :skipped, :failed, keyword_init: true) do
        def initialize(**)
          super
          members.each { |m| self[m] ||= [] }
        end
      end

      def initialize(settings, manifest:, shell: Shell.new, out: $stdout)
        @manifest = manifest
        @shell = shell
        @out = out
        @excludes = Array(settings[:exclude_folders]).map { |e| "--exclude=#{e}" }
        @share_paths = Array(settings[:sources]).to_h do |e|
          path = e.is_a?(Hash) ? e[:path] : e.to_s
          [File.basename(path), path]
        end
      end

      # +targets+ are folder_paths ("tv/Breaking Bad") or share names ("tv"),
      # expanded to every folder currently in the manifest under that share.
      # Raises if a name matches nothing placed.
      def resolve(targets)
        all = @manifest.folders
        targets.flat_map do |t|
          exact = all.find { |f| f.folder_path == t }
          next [exact] if exact

          under_share = all.select { |f| f.folder_path.start_with?("#{t}/") }
          raise UnknownTarget, "#{t} matches no placed folder or share" if under_share.empty?

          under_share
        end.uniq(&:folder_path)
      end

      # +folders+ are Folder structs from the manifest; +mounted+ are this
      # run's MountedDrive structs. Returns a Result.
      def run(folders, mounted, dry_run: false)
        result = Result.new
        by_serial = mounted.to_h { |m| [m.serial_number, m] }
        folders.each { |folder| restore_one(folder, by_serial, result, dry_run: dry_run) }
        result
      end

      private

      def restore_one(folder, by_serial, result, dry_run:)
        drive = by_serial[folder.drive_serial]
        if drive.nil?
          name = @manifest.drive(folder.drive_serial)&.friendly_name || folder.drive_serial
          return skip(result, folder.folder_path, "its drive #{name} is not mounted")
        end

        root = share_root(folder.folder_path)
        if root.nil?
          share = folder.folder_path.split('/').first
          return skip(result, folder.folder_path, "#{share} is not a configured source; `add-source` it first")
        end
        return skip(result, folder.folder_path, "the NAS share is not mounted at #{root}") unless Dir.exist?(root)

        destination = nas_destination(folder.folder_path)

        source = File.join(drive.mount_point, folder.folder_path)
        return skip(result, folder.folder_path, "nothing at #{source} on #{drive.friendly_name}") unless Dir.exist?(source)

        @out.puts "\n------------------ #{folder.folder_path}: #{drive.friendly_name} -> NAS ------------------"
        rsync_result = restore_copy(source, destination, dry_run: dry_run)
        if rsync_result.success?
          result.restored << folder.folder_path
        else
          @out.puts "WARNING: rsync for #{folder.folder_path} exited with status #{rsync_result.status}"
          result.failed << folder.folder_path
        end
      end

      # No --delete, ever: restoring must never remove anything already on the NAS.
      def restore_copy(source, destination, dry_run:)
        FileUtils.mkdir_p(File.dirname(destination)) unless dry_run
        argv = ['rsync', '-a', '--partial', '--stats', '--info=progress2', '--itemize-changes', *@excludes]
        argv << '--dry-run' if dry_run
        argv += [with_slash(source), with_slash(destination)]
        @shell.run(argv)
      end

      def share_root(folder_path)
        @share_paths[folder_path.split('/').first]
      end

      def nas_destination(folder_path)
        share, rest = folder_path.split('/', 2)
        root = @share_paths[share] or return nil

        rest ? File.join(root, rest) : root
      end

      def skip(result, folder_path, why)
        @out.puts "WARNING: skipping #{folder_path}: #{why}"
        result.skipped << folder_path
      end

      def with_slash(path)
        path.end_with?('/') ? path : "#{path}/"
      end
    end
  end
end
