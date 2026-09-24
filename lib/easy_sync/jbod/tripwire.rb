# frozen_string_literal: true

module EasySync
  module Jbod
    # Decides whether a sync would overwrite too much of the backup at once:
    # far more existing files replaced or gone on the NAS than a media library
    # ever changes normally, which is what ransomware looks like. Pure logic
    # over the per-folder Mirror::Check results; Runner acts on the Decision.
    # See docs/tripwire.md.
    class Tripwire
      # +scope+ is 'folder' when the folder tripped on its own, 'run' when it
      # only counts towards a run-wide trip.
      Trip = Struct.new(:folder_path, :replaced, :missing, :files_on_drive, :samples, :scope, :accepted,
                        keyword_init: true) do
        def changed = replaced + missing
      end

      # +trips+ includes accepted ones (they are still recorded). +blocked+
      # is the folder keys not to copy this run; with +run_tripped+ nothing
      # is copied at all. +run_changed+ is the changed-file total the run
      # threshold was compared against (accepted folders left out).
      Decision = Struct.new(:trips, :run_tripped, :run_changed, :total_changed, keyword_init: true) do
        def blocked = trips.reject(&:accepted).map(&:folder_path)
        def tripped? = !blocked.empty?
      end

      attr_reader :run_files, :folder_files, :folder_ratio

      def self.from_settings(settings)
        new(run_files: settings.fetch(:tripwire_run_files, 500), folder_files: settings.fetch(:tripwire_folder_files, 50),
            folder_ratio: settings.fetch(:tripwire_folder_ratio, 0.25))
      end

      def initialize(run_files:, folder_files:, folder_ratio:)
        @run_files = run_files.to_i
        @folder_files = folder_files.to_i
        @folder_ratio = folder_ratio.to_f
      end

      # 0 turns the tripwire off entirely: nothing ever trips.
      def enabled? = run_files.positive?

      # +checks+ maps folder key => Mirror::Check. +accept+ is true (accept
      # every trip this run), an array of folder keys, or nil.
      def decide(checks, accept: nil)
        accepted = ->(key) { accept == true || Array(accept).include?(key) }
        total = checks.sum { |_, c| c.changed }
        run_changed = checks.sum { |key, c| accepted.call(key) ? 0 : c.changed }
        return Decision.new(trips: [], run_tripped: false, run_changed: run_changed, total_changed: total) unless enabled?

        # Accepting everything still records the trip it let through.
        run_trip = run_changed >= run_files || (accept == true && total >= run_files)
        trips = checks.filter_map do |key, check|
          alone = folder_trips?(check)
          next unless alone || (run_trip && check.changed.positive?)

          trip(key, check, scope: alone ? 'folder' : 'run', accepted: accepted.call(key))
        end
        Decision.new(trips: trips, run_tripped: run_changed >= run_files, run_changed: run_changed, total_changed: total)
      end

      # Both halves: enough files that it isn't a 3-file folder with one
      # re-tag, and a big enough share that it isn't routine churn in a
      # huge one.
      def folder_trips?(check)
        changed = check.changed
        return false if changed < folder_files || changed.zero?

        changed.fdiv([check.files_on_drive, changed].max) >= folder_ratio
      end

      private

      def trip(key, check, scope:, accepted:)
        Trip.new(folder_path: key, replaced: check.replaced.size, missing: check.missing_files.size,
                 files_on_drive: check.files_on_drive, samples: check.samples, scope: scope, accepted: accepted)
      end
    end
  end
end
