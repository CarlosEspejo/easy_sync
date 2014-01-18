require 'spec_helper'

describe Rsync do

  it "should find the latest snapshot directory" do
    Rsync.new(source_directory, destination_directory).latest_snapshot.must_equal File.join(destination_directory, "2013-12-30")
  end

  it "should create the new snapshot directory" do
    Rsync.new(source_directory, destination_directory).current_snapshot.must_equal File.join(destination_directory, Time.now.strftime("%Y-%m-%d"))
  end

 end
