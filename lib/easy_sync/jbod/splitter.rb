# frozen_string_literal: true

module EasySync
  module Jbod
    # `easy_sync split SHARE`: converts a share an earlier build placed whole
    # into one folder per top-level subfolder plus a root-files unit, all on
    # the drive that already holds it. No data is
    # copied: <drive>/<share>/<sub> is already exactly where the new folders
    # expect their files, so the next sync's quick check finds them in place.
    #
    # Every top-level directory found on the NAS *or* on the drive becomes a
    # folder. One that is only on the drive (deleted from the NAS since the
    # last sync) is then an ordinary folder missing on the NAS, and the
    # normal grace period removes it: nothing is left behind untracked.
    class Splitter
      Plan = Struct.new(:share, :drive, :units, :root_size, :drive_only, keyword_init: true)

      def initialize(settings, manifest:, volume_info:, shell: Shell.new, out: $stdout, sizer: nil)
        @settings = settings
        @manifest = manifest
        @volume_info = volume_info
        @shell = shell
        @out = out
        @sizer = sizer || method(:du_bytes)
      end

      # Nothing is written with +dry_run+. Returns the Plan, or nil when the
      # share has nothing to split (already split, or never placed whole).
      def run(share, dry_run: false)
        plan = build_plan(share) or return nil

        describe(plan, dry_run: dry_run)
        return plan if dry_run

        @manifest.split_whole_folder(share, units: plan.units, root_size: plan.root_size,
                                            note: "split from #{share} on #{plan.drive.friendly_name} (no data moved)")
        @out.puts "#{share} is now #{plan.units.size} folder#{'s' if plan.units.size != 1} plus its loose files, " \
                  "all on #{plan.drive.friendly_name}. The next sync checks them in place."
        plan
      end

      private

      def build_plan(share)
        source = source_path(share)
        whole = @manifest.folder(share)
        if whole.nil? || whole.root?
          @out.puts "#{share} is not placed whole; its folders are already placed one by one. Nothing to do."
          return nil
        end
        raise Error, "#{source} is not mounted (or is empty); split reads the share's folders from the NAS" \
          unless Dir.exist?(source) && !Dir.empty?(source)

        check_pending!(share)
        drive = @manifest.drive(whole.drive_serial)
        mounted = @volume_info.mounted_drives([drive]).first or
          raise Error, "connect #{drive.friendly_name} first; split reads what is already on it"

        excludes = @settings[:exclude_folders]
        on_drive = File.join(mounted.mount_point, share)
        nas_names = ShareScan.subfolders(source, excludes)
        drive_names = Dir.exist?(on_drive) ? ShareScan.subfolders(on_drive, excludes) : []
        units = (nas_names | drive_names).sort.map do |name|
          path = nas_names.include?(name) ? File.join(source, name) : File.join(on_drive, name)
          [name, @sizer.call(path)]
        end
        root_size = ShareScan.loose_files(source, excludes).sum { |n| File.size(File.join(source, n)) }
        Plan.new(share: share, drive: drive, units: units, root_size: root_size, drive_only: drive_names - nas_names)
      end

      # A copy left on another drive by an earlier `reassign` is waiting for
      # Purger as one whole folder. After a split that row would describe
      # only the loose files, and the old copy's subfolders would never be
      # cleaned up, so wait for it to go first.
      def check_pending!(share)
        pending = @manifest.pending_deletions(folder_path: share)
        if (old = pending.find(&:reassigned?))
          name = @manifest.drive(old.drive_serial)&.friendly_name || old.drive_serial
          raise Error, "an older copy of #{share} on #{name} is still waiting to be deleted after a reassign; " \
                       'split it once that is done (see `easy_sync pending`)'
        end
        return unless pending.any? { |p| p.whole_folder? && p.relative_path.empty? }

        raise Error, "#{share} is itself pending deletion as missing on the NAS; resolve that first"
      end

      def describe(plan, dry_run:)
        verb = dry_run ? 'Would split' : 'Splitting'
        @out.puts "#{verb} #{plan.share} on #{plan.drive.friendly_name} into #{plan.units.size} " \
                  "folder#{'s' if plan.units.size != 1} plus its loose files (#{Placement.format_bytes(plan.root_size)}). " \
                  'No data is copied.'
        plan.units.each do |name, size|
          gone = plan.drive_only.include?(name) ? '  (only on the drive: gone from the NAS, deleted after the grace period)' : ''
          @out.puts "  #{plan.share}/#{name}  #{Placement.format_bytes(size)}#{gone}"
        end
      end

      def source_path(share)
        entry = Array(@settings[:sources]).find { |e| File.basename(e.is_a?(Hash) ? e[:path] : e.to_s) == share }
        raise Error, "#{share} is not a configured source" unless entry

        entry.is_a?(Hash) ? entry[:path] : entry.to_s
      end

      def du_bytes(path)
        result = @shell.capture(['du', '-sk', path])
        raise Error, "du failed for #{path}: #{result.output}" unless result.success?

        Integer(result.output.split.first) * 1024
      end
    end
  end
end
