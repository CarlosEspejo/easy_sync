# frozen_string_literal: true

require_relative 'jbod/models'
require_relative 'jbod/manifest'
require_relative 'jbod/placement'
require_relative 'jbod/volume_info'
require_relative 'jbod/mirror'
require_relative 'jbod/purger'
require_relative 'jbod/run_lock'
require_relative 'jbod/keep_awake'
require_relative 'jbod/dashboard'
require_relative 'jbod/runner'

module EasySync
  # Folder-level mirroring from a NAS share onto independently mounted drives.
  module Jbod
    MARKER_FILE = '.easy_sync_drive.json'
  end
end
