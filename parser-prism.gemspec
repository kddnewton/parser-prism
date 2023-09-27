# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "parser-prism"
  spec.version = "0.1.0"
  spec.authors = ["Kevin Newton"]
  spec.email = ["kddnewton@gmail.com"]

  spec.summary = "A prism parser backend"
  spec.homepage = "https://github.com/kddnewton/parser-prism"
  spec.license = "MIT"

  spec.files =
    Dir.chdir(__dir__) do
      `git ls-files -z`.split("\x0")
        .reject { |f| f.match(%r{^(test|spec|features)/}) }
    end

  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "parser"
  spec.add_dependency "prism"
end
