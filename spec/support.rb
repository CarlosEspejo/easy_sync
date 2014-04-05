require 'fileutils'
require 'tmpdir'
require 'time'


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
  "#{@source_directory}/"
end

def destination_directory
  @destination_directory
end

def create_snapshot_directories
  %w{2013-12-30 2013-11-10 2013-10-10 2013-11-07}.each do |date|
    path = File.join destination_directory, date

    Dir.mkdir path
    time = Time.parse date

    File.utime(time, time, path)

  end
end

def create_source_files
  %w{file1.txt file2.txt file3.txt file4.txt}.each do |file|
    File.open(File.join(source_directory, file), 'w'){|f| f.puts "This is some sample text"}
  end

end

def copy_to_latest
  %w{file1.txt file2.txt file3.txt}.each do |file|
    FileUtils.cp File.join(source_directory, file), File.join(destination_directory, "2013-12-30")
  end
end

def blank_config_file
  @blank_config_file ||= "#{temp_directory}/.easy_syncrc.yml"
end

def config_file_data
  @config_file_data ||= {
                          rsync_log_setting: :off,
                          mappings: [
                            {
                              sync_name: "test_sync",
                              source: "#{source_directory}",
                              destination: "#{destination_directory}",
                              exclude_file: ""
                            }]
                        }
end

def config_file
  File.open(blank_config_file, 'w'){|f| f.puts config_file_data.to_yaml}
  blank_config_file
end
