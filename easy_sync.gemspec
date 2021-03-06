# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'easy_sync/version'

Gem::Specification.new do |spec|
  spec.name          = "easy_sync"
  spec.version       = EasySync::VERSION
  spec.authors       = ["Carlos Espejo"]
  spec.email         = ["carlosespejo@gmail.com"]
  spec.summary       = %q{Ruby wrapper around rsync to easily create incremental backups.}
  #spec.description   = %q{TODO: Write a longer description. Optional.}
  spec.homepage      = "https://github.com/CarlosEspejo/easy_sync"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.5"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "guard-minitest"
  spec.add_development_dependency "terminal-notifier-guard"

end
