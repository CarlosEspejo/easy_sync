require 'spec_helper'

describe SyncRunner do

  it "should create template config if no config file passed" do
    SyncRunner.new({config_file: config_file})
    File.exist?(config_file).must_equal true
  end

  it "should use config file" do
    File.open(config_file, "w"){|f| f.puts [{source: "source path", destination: "dest path", exclude_file: "exclude-from path"}].to_yaml}

    SyncRunner.new(config_file: config_file).config.size.must_equal 1
  end

end
