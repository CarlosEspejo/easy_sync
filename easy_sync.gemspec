# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'easy_sync/version'

Gem::Specification.new do |spec|
  spec.name          = 'easy_sync'
  spec.version       = EasySync::VERSION
  spec.authors       = ['Carlos Espejo']
  spec.email         = ['carlosespejo@gmail.com']
  spec.summary       = 'Folder-level rsync backups from a NAS onto a set of independent (JBOD) drives.'
  spec.description   = 'Mirrors each folder of your NAS shares onto one of several independently mounted ' \
                       'drives, tracks where everything lives in a SQLite manifest with a grace period ' \
                       'before deletions, and writes an HTML status dashboard with SMART health.'
  spec.homepage      = 'https://github.com/CarlosEspejo/easy_sync'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.3'
  spec.metadata['platform_note'] = 'macOS only (10.13 High Sierra or later): relies on diskutil and caffeinate'

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.start_with?('spec/') }
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'sqlite3', '~> 2.9'
  # logger left the standard library in Ruby 4.0 and must be declared explicitly.
  spec.add_dependency 'logger', '~> 1.6'
  # fiddle is a bundled (not default) gem in Ruby 4.0; scrub uses it to evict
  # a file's cached pages before hashing (see Jbod::PageCache).
  spec.add_dependency 'fiddle', '~> 1.1'

  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.13'
end
