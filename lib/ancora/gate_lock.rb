# frozen_string_literal: true

module Ancora
  # The gate lock: a Gemfile pinning the ENTIRE chain inventory at exact
  # versions - the wave's candidates for the gems under gate, released
  # floors for everything else. Bundler never resolves prereleases
  # implicitly, so multi-level candidate chains must be pinned exactly.
  # External chains (gems outside the inventory) are pinned at their
  # satisfying FINALS when findings are supplied: the gate never
  # validates "latest", and nothing promotes against another chain's
  # prerelease - a need with no satisfying final blocks the lock.
  class GateLock
    SOURCE = "https://rubygems.org"

    def initialize(chain, graph, externals: [])
      @chain = chain
      @graph = graph
      @externals = externals
    end

    def pins(candidates = {})
      inventory.each_with_object({}) do |gem, pins|
        version = candidates[gem] || released_version(gem)
        pins[gem] = version if version
      end
    end

    # external needs with no satisfying final: the lock cannot complete
    def awaiting
      @externals.select { |f| f.status == :awaiting_release }
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
      body.concat(external_pins)
      body.concat(awaiting.map do |f|
        "# AWAITING RELEASE: #{f.from.join(', ')} -> #{f.gem} " \
          "(#{f.constraints.join(', ')}); latest final #{f.latest_final || 'none'}"
      end)
      (header + body + [""]).join("\n")
    end

    private

    def external_pins
      pins = @externals.select { |f| f.status == :satisfied }
        .sort_by(&:gem).map { |f| %(gem "#{f.gem}", "#{f.latest_final}") }
      return [] if pins.empty?

      pins.unshift("# external chains - finals (promote-gate truth)")
    end

    def inventory
      @chain.inventory(@graph)
    end

    def released_version(gem)
      node = @graph.nodes[gem]
      node&.released || node&.main_version
    end
  end
end
