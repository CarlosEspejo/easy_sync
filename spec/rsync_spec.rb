require 'spec_helper'

describe Rsync do

  it "should find the latest snapshot directory" do
    Rsync.new(config_file_data) \
          .latest_snapshot.must_equal File.join(destination_directory, "2013-12-30")
  end

  it "should create the new snapshot directory" do
    Rsync.new(config_file_data) \
          .current_snapshot.must_equal File.join(destination_directory, Time.now.strftime("%Y-%m-%d"))
  end

  it "should log to a file" do
    Rsync.new(config_file_data).sync
    File.exist?("#{temp_directory}/test_sync.log").must_equal true
  end

 end
