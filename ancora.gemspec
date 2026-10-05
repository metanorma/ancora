# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "ancora"
  spec.version = "0.1.0"
  spec.authors = ["Ribose"]
  spec.email = ["open.source@ribose.com"]

  spec.summary = "Dependency-ordered release wave orchestrator for gem fleets"
  spec.description = "Ancora (Latin: anchor) plans, gates, and releases gem " \
    "fleets in dependency order: candidate prereleases per wave, integration " \
    "gates over pinned sets, canary corpora, and promotion to finals - with " \
    "rubygems, CI runs, and git tags as the only source of truth."
  spec.homepage = "https://github.com/metanorma/ancora"
  spec.license = "MIT"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.adoc", "TODO.md"]
  spec.bindir = "exe"
  spec.executables = ["ancora"]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.0"

  spec.add_development_dependency "rspec", "~> 3.13"
end
