# frozen_string_literal: true

require 'easy_sync'
require 'tmpdir'
require 'fileutils'
require 'stringio'

Dir[File.join(__dir__, 'support', '**', '*.rb')].sort.each { |f| require f }

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.mock_with(:rspec) { |c| c.verify_partial_doubles = true }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.include FakeShellHelpers
  config.include TempDirHelpers

  # The suite must never look at, let alone move, a real config in the
  # developer's home directory. Point every default path into the temp dir.
  config.before do
    stub_const('EasySync::Config::HOME_DIR', File.join(temp_dir, 'home', '.easy_sync'))
    stub_const('EasySync::Config::LEGACY_PATH', File.join(temp_dir, 'home', '.easy_syncrc.yml'))
  end
end
