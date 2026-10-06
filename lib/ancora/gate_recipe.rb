# frozen_string_literal: true

module Ancora
  # The gate recipe: everything a runtime run needs to execute a gate -
  # the lock pinning the ENTIRE candidate set (bundler never resolves
  # prereleases implicitly), one suite invocation per gated gem, and the
  # canary commands (unit-green does not mean works: the cg3 lesson -
  # a real corpus document compiled end to end including presentation
  # and site rendering). Commands come from chain.yml; the engine only
  # composes them with the attempt's pins.
  class GateRecipe
    Suite = Struct.new(:gem, :repo, :commands, keyword_init: true)
    Recipe = Struct.new(:lockfile, :suites, :canary, :corpora,
                        keyword_init: true)

    def initialize(chain, graph)
      @chain = chain
      @graph = graph
    end

    def build(pins)
      Recipe.new(
        lockfile: GateLock.new(@chain, @graph).gemfile(pins),
        suites: pins.keys.sort.map do |gem|
          Suite.new(gem: gem, repo: @graph.nodes[gem]&.repo,
                    commands: @chain.gate_commands)
        end,
        canary: @chain.canary_commands,
        corpora: @chain.corpora_for(pins.keys),
      )
    end
  end
end
