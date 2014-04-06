require 'spec_helper'

describe SyncRunner do

  it "should create template config if no config file passed" do
    SyncRunner.new
    config = YAML.load_file default_config_path
    config.must_equal blank_config
  end

  it "should use default config file" do
    File.open(default_config_path, "w"){|f| f.puts config_file_data.merge({logging: :off}).to_yaml}
    SyncRunner.new.config[:logging].must_equal :off
  end

  it "should sync files between source and destination" do
    create_config_file
    SyncRunner.new.run
    Dir["#{File.join(destination_directory, Time.now.strftime("%Y-%m-%d"))}/*"].map{|f| File.basename f}.must_equal ["file1.txt", "file2.txt", "file3.txt", "file4.txt"]
  end

  it "should create hard links to the files that didn't change in the new snapshot directory" do
    create_config_file
    SyncRunner.new.run

    snapshot_file = Dir["#{File.join(destination_directory, "2013-12-30")}/*"].first
    new_file = Dir["#{File.join(destination_directory, Time.now.strftime("%Y-%m-%d"))}/*"].first

    File.stat(snapshot_file).ino.must_equal File.stat(new_file).ino
  end

  it "should use exclude-from option" do
    exclude_file = "#{destination_directory}/exclude.txt"
    File.open(exclude_file, "w"){|f| f.puts "file4.txt"}

    config_file_data[:tasks].first[:exclude_file] = exclude_file
    File.open(default_config_path, 'w'){|f| f.puts config_file_data.to_yaml}

    SyncRunner.new.run

    Dir["#{File.join(destination_directory, Time.now.strftime("%Y-%m-%d"))}/*"].map{|f| File.basename f}.must_equal ["file1.txt", "file2.txt", "file3.txt"]
  end

  it "should apply log setting to all task" do
    log_file = "#{temp_directory}/.easy_sync.log"
    create_config_file
    s = SyncRunner.new
    s.config[:logging] = :on
    s.run

    File.exist?(log_file).must_equal true
  end

end
