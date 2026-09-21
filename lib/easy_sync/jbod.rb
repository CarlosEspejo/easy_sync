# frozen_string_literal: true

require_relative 'jbod/models'
require_relative 'jbod/manifest'
require_relative 'jbod/placement'
require_relative 'jbod/volume_info'
require_relative 'jbod/mirror'
require_relative 'jbod/restorer'
require_relative 'jbod/purger'
require_relative 'jbod/cleaner'
require_relative 'jbod/run_lock'
require_relative 'jbod/keep_awake'
require_relative 'jbod/planner'
require_relative 'jbod/run_log'
require_relative 'jbod/sync_eta'
require_relative 'jbod/dashboard'
require_relative 'jbod/page_cache'
require_relative 'jbod/scrubber'
require_relative 'jbod/runner'

module EasySync
  # Folder-level mirroring from a NAS share onto independently mounted drives.
  module Jbod
    # Everything easy_sync keeps on a drive lives in this folder at its root:
    # the identity marker, and after every run a copy of the manifest and
    # config so any single surviving drive can rebuild the map.
    DRIVE_DIR = '.easy_sync'
    MARKER_FILE = File.join(DRIVE_DIR, 'drive.json')
  end
end
