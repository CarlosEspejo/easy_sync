require 'spec_helper'
require 'fileutils'
require 'tmpdir'

describe Rsync do
#Time.now.strftime "%Y-%m-%d-%H%M%S"
  before do
    create_root_dir
  end

  it "should find the latest snapshot" do
    Rsync.new("","").last_snapshot.must_equal ""
  end

  after do
    FileUtils.rm_r @temp_dir
  end

  def temp_files

  end

  def create_root_dir
    @temp_dir = Dir.mktmpdir('test_data', File.expand_path('./', File.dirname(__FILE__)))
  end

end
