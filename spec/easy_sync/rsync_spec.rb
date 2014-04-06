require 'spec_helper'

describe Rsync do

  let(:task){config_file_data[:tasks].first}

  it "should find the latest snapshot directory" do
    Rsync.new(task) \
          .latest_snapshot.must_equal File.join(destination_directory, "2013-12-30")
  end

  it "should create the new snapshot directory" do
    Rsync.new(task) \
          .current_snapshot.must_equal File.join(destination_directory, Time.now.strftime("%Y-%m-%d"))
  end

  it "should log to a file" do
    log_file = "#{temp_directory}/.easy_sync.log"
    task[:logging] = :on

    Rsync.new(task).sync
    File.exist?(log_file).must_equal true
  end

end
