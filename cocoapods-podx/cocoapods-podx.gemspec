Gem::Specification.new do |spec|
  spec.name          = 'cocoapods-podx'
  spec.version       = "0.0.50"
  spec.summary       = 'Podx workflow helpers for private CocoaPods components'
  spec.description   = 'Adds podx and mgit helpers to switch private CocoaPods components between local and remote sources.'
  spec.authors       = ['Codex']
  spec.email         = ['noreply@example.com']
  spec.homepage      = 'http://git.leigod.top/nn_ios/nnios'
  spec.license       = 'MIT'

  spec.files         = Dir[
    'bin/*',
    'lib/**/*.rb'
  ]
  spec.bindir        = 'bin'
  spec.executables   = %w[podx mgit]
  spec.require_paths = ['lib']

  spec.add_dependency 'cocoapods', '>= 1.11', '< 2.0'
end
