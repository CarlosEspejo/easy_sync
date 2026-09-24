# frozen_string_literal: true

require 'time'

module EasySync
  module Jbod
    # Estimates time remaining for a sync run in progress, from what it has
    # actually done so far this run: folders it copied real bytes for (their
    # rate extrapolates to every not-yet-synced folder still queued) plus
    # folders it merely re-verified (their average time extrapolates to every
    # already-synced folder not yet touched this run, unless that folder has
    # a verify of its own from an earlier run, which is used instead: a
    # share's folders run together, so the first few verifies of a run can
    # be one slow share's (many small files over SMB) and say nothing about
    # thousands of single-file movie folders still to come). The two behave nothing
    # alike - an unchanged folder verifies in under a second, a first-time
    # folder moves real bytes over the network - so averaging them together
    # would be meaningless; this keeps them separate instead. Shared by
    # `status` and the dashboard so the two never drift apart.
    class SyncEta
      # +status+ is :waiting_for_first_folder (nothing has finished this run
      # yet), :waiting_for_first_transfer (only verifies so far, no rate to
      # extrapolate from), or :estimate (the only one with usable +seconds+).
      Estimate = Struct.new(:status, :never_synced_count, :never_synced_bytes, :to_reverify, :seconds,
                            keyword_init: true)

      def self.for(manifest, started_at) = new(manifest, started_at).estimate

      def initialize(manifest, started_at)
        @manifest = manifest
        @started_at = started_at
      end

      # nil when the run has nothing left to estimate (every folder was
      # already touched this run as of the moment it started).
      def estimate
        since = @started_at.utc.iso8601
        runs = @manifest.sync_runs_since(since)
        return Estimate.new(status: :waiting_for_first_folder) if runs.empty?

        transfers, verifies = runs.partition { |r| r.bytes_transferred.to_i.positive? }
        transfer_seconds = duration_of(transfers)
        transfer_rate = transfer_seconds.positive? ? transfers.sum { |r| r.bytes_transferred.to_i } / transfer_seconds : nil
        avg_verify_seconds = verifies.empty? ? duration_of(runs) / runs.size : duration_of(verifies) / verifies.size

        folders = @manifest.folders
        never_synced = folders.select { |f| f.last_synced_at.nil? }
        reverify = folders.select { |f| f.last_synced_at && f.last_synced_at < since }
        return nil if never_synced.empty? && reverify.empty?

        if never_synced.any? && transfer_rate.nil?
          return Estimate.new(status: :waiting_for_first_transfer, never_synced_count: never_synced.size,
                              never_synced_bytes: never_synced.sum { |f| f.size_bytes.to_i })
        end

        transfer_part = transfer_rate ? never_synced.sum { |f| f.size_bytes.to_i } / transfer_rate : 0
        history = @manifest.last_verify_seconds(before: since)
        reverify_part = reverify.sum { |f| history.fetch(f.folder_path, avg_verify_seconds) }
        Estimate.new(status: :estimate, never_synced_count: never_synced.size, to_reverify: reverify.size,
                    seconds: transfer_part + reverify_part)
      end

      private

      def duration_of(runs) = runs.sum { |r| Time.parse(r.finished_at) - Time.parse(r.started_at) }
    end
  end
end
