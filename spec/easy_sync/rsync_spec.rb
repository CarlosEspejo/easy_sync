require 'spec_helper'

describe Rsync do

  let(:mapping){config_file_data[:mappings].first}

  it "should find the latest snapshot directory" do
    Rsync.new(mapping) \
          .latest_snapshot.must_equal File.join(destination_directory, "2013-12-30")
  end

  it "should create the new snapshot directory" do
    Rsync.new(mapping) \
          .current_snapshot.must_equal File.join(destination_directory, Time.now.strftime("%Y-%m-%d"))
  end

  it "should log to a file" do
    log_file = "#{temp_directory}/test_sync.log"
    logger = Logger.new(log_file)
    config_file_data[:logger] = logger

    Rsync.new(mapping).sync
    File.exist?(log_file).must_equal true
  end

end
