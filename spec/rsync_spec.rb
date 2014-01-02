require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'time'

describe Rsync do

  before do
    create_root_directory
    create_source_directory
    create_destination_directory
    create_empty_snapshots
    create_source_files
  end

  it "should find the latest snapshot directory" do
    Rsync.new(source_directory, destination_directory).latest_snapshot.must_equal File.join(destination_directory, "2013-12-30")
  end

  it "should create the new snapshot directory" do
    Rsync.new(source_directory, destination_directory).current_snapshot.must_equal File.join(destination_directory, Time.now.strftime("%Y-%m-%d"))
  end

  it "should sync files between source and destination" do
    r = Rsync.new(source_directory, destination_directory)
    r.sync

    Dir["#{source_directory}/*"].map{|f| File.basename f}.must_equal ["file1.txt", "file2.txt", "file3.txt"]
  end



  after do
    FileUtils.rm_r temp_directory
  end

  def create_root_directory
    @temp_directory = Dir.mktmpdir('test_data', File.expand_path('./', File.dirname(__FILE__)))
  end

  def temp_directory
    @temp_directory
  end

  def create_source_directory
    @source_directory = File.join(temp_directory, 'source')
    Dir.mkdir @source_directory
  end

  def create_destination_directory
    @destination_directory = File.join(temp_directory, 'backup')
    Dir.mkdir @destination_directory
  end

  def source_directory
    @source_directory
  end

  def destination_directory
    @destination_directory
  end

  def create_empty_snapshots
    %w{2013-12-30 2013-11-10 2013-10-10 2013-11-07}.each do |date|
      path = File.join destination_directory, date

      Dir.mkdir path
      time = Time.parse date

      File.utime(time, time, path)

    end
  end

  def create_source_files
    %w{file1.txt file2.txt file3.txt}.each do |file|
      FileUtils.touch File.join(source_directory, file)
    end

  end

end
