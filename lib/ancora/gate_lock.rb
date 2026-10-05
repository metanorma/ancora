# frozen_string_literal: true

module Ancora
  # The gate lock: a Gemfile pinning the ENTIRE chain inventory at exact
  # versions - the wave's candidates for the gems under gate, released
  # floors for everything else. Bundler never resolves prereleases
  # implicitly, so multi-level candidate chains must be pinned exactly;
  # externals (other chains, third-party gems) are left to bundler,
  # which can only ever pick finals.
  class GateLock
    SOURCE = "https://rubygems.org"

    def initialize(chain, graph)
      @chain = chain
      @graph = graph
    end

    def pins(candidates = {})
      inventory.each_with_object({}) do |gem, pins|
        version = candidates[gem] || released_version(gem)
        pins[gem] = version if version
      end
    end

    def gemfile(candidates = {})
      pinned = pins(candidates)
      header = [
        "# frozen_string_literal: true",
        "# gate lock: chain #{@chain.name} - exact pins for the whole " \
        "inventory (#{pinned.size} gems)",
        %(source "#{SOURCE}"),
        "",
      ]
      body = pinned.keys.sort.map { |gem| %(gem "#{gem}", "#{pinned[gem]}") }
      missing = (inventory - pinned.keys).sort
      body.concat(missing.map { |gem| "# #{gem}: no version on record" })
      (header + body + [""]).join("\n")
    end

    private

    def inventory
      @chain.inventory(@graph)
    end

    def released_version(gem)
      node = @graph.nodes[gem]
      node&.released || node&.main_version
    end
  end
end
