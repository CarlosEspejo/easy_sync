require "minitest/autorun"
require "minitest/pride"
require 'pry'

require 'easy_sync'
require_relative 'support'

include EasySync

class MiniTest::Spec

  before do
    create_root_directory
    create_source_directory
    create_destination_directory
    create_snapshot_directories
    create_source_files
    copy_to_latest

    # output is not needed for running test cases
    #$stdout = StringIO.new
  end


  after do
    FileUtils.rm_r temp_directory
    #$stdout = STDOUT
  end

end
