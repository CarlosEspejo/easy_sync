require "minitest/autorun"
require "minitest/pride"
require 'pry'

require 'easy_sync'
require 'support'

include EasySync

class MiniTest::Spec

  before do
    create_root_directory
    create_source_directory
    create_destination_directory
    create_snapshot_directories
    create_source_files
    copy_to_latest
  end


  after do
    FileUtils.rm_r temp_directory
  end

end
