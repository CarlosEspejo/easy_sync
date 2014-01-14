require 'spec_helper'

describe SyncRunner do
  before do
    create_root_directory
  end

  it "should raise exception if no config file passed" do
    lambda{SyncRunner.new({})}.must_raise RuntimeError
  end

  it "should use config file" do
    config_path = "#{temp_directory}/config.yml"
    File.open(config_path, "w"){|f| f.puts [{source: "source path", destination: "dest path", exclude_file: "exclude-from path"}].to_yaml}

    SyncRunner.new(config_file: config_path).config.size.must_equal 1
  end

  def create_root_directory
    @temp_directory = Dir.mktmpdir('test_data', File.expand_path('./', File.dirname(__FILE__)))
  end

  def temp_directory
    @temp_directory
  end

  after do
    FileUtils.rm_r temp_directory
  end

end
