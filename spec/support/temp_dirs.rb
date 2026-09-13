# frozen_string_literal: true

module TempDirHelpers
  def temp_dir
    @temp_dir ||= Dir.mktmpdir('easy_sync_spec')
  end

  def make_dirs(root, *names)
    names.map { |n| File.join(root, n).tap { |p| FileUtils.mkdir_p(p) } }
  end

  def write_file(path, content = "sample\n")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end
end

RSpec.configure do |config|
  config.after do
    FileUtils.rm_rf(@temp_dir) if @temp_dir
  end
end
