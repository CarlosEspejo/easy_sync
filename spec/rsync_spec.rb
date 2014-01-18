require 'spec_helper'

describe Rsync do

  it "should find the latest snapshot directory" do
    Rsync.new(source_directory, destination_directory).latest_snapshot.must_equal File.join(destination_directory, "2013-12-30")
  end

  it "should create the new snapshot directory" do
    Rsync.new(source_directory, destination_directory).current_snapshot.must_equal File.join(destination_directory, Time.now.strftime("%Y-%m-%d"))
  end

  it "should sync files between source and destination" do
    Rsync.new(source_directory, destination_directory).sync

    Dir["#{File.join(destination_directory, Time.now.strftime("%Y-%m-%d"))}/*"].map{|f| File.basename f}.must_equal ["file1.txt", "file2.txt", "file3.txt", "file4.txt"]
  end

  it "should use exclude-from option" do
    exclude_file = "#{destination_directory}/exclude.txt"
    File.open(exclude_file, "w"){|f| f.puts "file4.txt"}

    Rsync.new(source_directory, destination_directory, exclude_file).sync

    Dir["#{File.join(destination_directory, Time.now.strftime("%Y-%m-%d"))}/*"].map{|f| File.basename f}.must_equal ["file1.txt", "file2.txt", "file3.txt"]
  end

  it "should create hard links to the files that didn't change in the new snapshot directory" do
    Rsync.new(source_directory, destination_directory).sync

    snapshot_file = Dir["#{File.join(destination_directory, "2013-12-30")}/*"].first
    new_file = Dir["#{File.join(destination_directory, Time.now.strftime("%Y-%m-%d"))}/*"].first

    File.stat(snapshot_file).ino.must_equal File.stat(new_file).ino
  end

end
