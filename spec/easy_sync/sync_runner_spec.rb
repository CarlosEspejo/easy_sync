require 'spec_helper'

describe SyncRunner do

  it "should create template config if no config file passed" do
    SyncRunner.new()
    File.exist?(blank_config_file).must_equal true
  end

  #it "should use config file" do
    #File.open(blank_config_file, "w"){|f| f.puts config_file_data.to_yaml}
    #SyncRunner.new(config_file: blank_config_file).config[:mappings].size.must_equal 1
  #end

  #it "should sync files between source and destination" do
    #SyncRunner.new(config_file: config_file).run
    #Dir["#{File.join(destination_directory, Time.now.strftime("%Y-%m-%d"))}/*"].map{|f| File.basename f}.must_equal ["file1.txt", "file2.txt", "file3.txt", "file4.txt"]
  #end

  #it "should create hard links to the files that didn't change in the new snapshot directory" do
    #SyncRunner.new(config_file: config_file).run

    #snapshot_file = Dir["#{File.join(destination_directory, "2013-12-30")}/*"].first
    #new_file = Dir["#{File.join(destination_directory, Time.now.strftime("%Y-%m-%d"))}/*"].first

    #File.stat(snapshot_file).ino.must_equal File.stat(new_file).ino
  #end

  #it "should use exclude-from option" do
    #exclude_file = "#{destination_directory}/exclude.txt"
    #File.open(exclude_file, "w"){|f| f.puts "file4.txt"}

    #config_file_data[:mappings].first[:exclude_file] = exclude_file
    #File.open(blank_config_file, 'w'){|f| f.puts config_file_data.to_yaml}

    #SyncRunner.new(config_file: config_file).run

    #Dir["#{File.join(destination_directory, Time.now.strftime("%Y-%m-%d"))}/*"].map{|f| File.basename f}.must_equal ["file1.txt", "file2.txt", "file3.txt"]
  #end

end
