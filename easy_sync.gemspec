# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'easy_sync/version'

Gem::Specification.new do |spec|
  spec.name          = 'easy_sync'
  spec.version       = EasySync::VERSION
  spec.authors       = ['Carlos Espejo']
  spec.email         = ['carlosespejo@gmail.com']
  spec.summary       = 'Ruby wrapper around rsync for incremental snapshots and JBOD backup management.'
  spec.description   = 'Creates incremental rsync snapshots, and manages folder-level backups from a ' \
                       'NAS onto a set of independently mounted JBOD drives with a SQLite manifest ' \
                       'and an HTML status dashboard.'
  spec.homepage      = 'https://github.com/CarlosEspejo/easy_sync'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.3'

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.start_with?('spec/') }
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'sqlite3', '~> 2.9'

  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.13'
end
