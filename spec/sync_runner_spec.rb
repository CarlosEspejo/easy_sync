require 'spec_helper'

describe SyncRunner do

  it "should create template config if no config file passed" do
    config = "#{temp_directory}/sample_sync.yml"
    SyncRunner.new({config_file: config})
    File.exist?("#{temp_directory}/sample_sync.yml").must_equal true
  end

  it "should use config file" do
    config_path = "#{temp_directory}/config.yml"
    File.open(config_path, "w"){|f| f.puts [{source: "source path", destination: "dest path", exclude_file: "exclude-from path"}].to_yaml}

    SyncRunner.new(config_file: config_path).config.size.must_equal 1
  end

end
