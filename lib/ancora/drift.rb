# frozen_string_literal: true

module Ancora
  # The drift report over collector data: floorless sibling edges (the
  # hidden-coupling class), stale pins (a floor that no longer admits
  # the dependency's main, forcing coordination), prerelease floors
  # (the lint class), and unreleased main (release drift plus gems
  # never released). Read-only; the standing feed for
  # cimas-drift-audit class (h). Chain-scoped when given a chain.
  class Drift
    StalePin = Struct.new(:from, :to, :constraints, :main_version,
                          keyword_init: true)
    Unreleased = Struct.new(:gem, :ahead_by, :main_version, keyword_init: true)
    Report = Struct.new(:floorless, :stale_pins, :prerelease_floors,
                        :unreleased, keyword_init: true)

    def initialize(graph, chain: nil)
      @graph = graph
      @chain = chain
    end

    def report
      edges = @graph.edges
      edges = edges.select { |e| inventory.include?(e.from) } if @chain
      scope = @chain ? inventory : @graph.nodes.keys
      Report.new(
        floorless: edges.select { |e| e.constraints.empty? },
        stale_pins: edges.filter_map { |e| stale_pin(e) },
        prerelease_floors: edges.select { |e| prerelease_floor?(e) },
        unreleased: scope.filter_map { |gem| unreleased(gem) }.sort_by(&:gem),
      )
    end

    private

    def inventory
      @inventory ||= @chain.inventory(@graph)
    end

    def stale_pin(edge)
      return if edge.constraints.empty?

      node = @graph.nodes[edge.to]
      main = node&.main_version
      return if main.nil? || Gem::Version.new(main).prerelease?

      requirement = Gem::Requirement.new(*edge.constraints)
      return if requirement.satisfied_by?(Gem::Version.new(main))

      StalePin.new(from: edge.from, to: edge.to, constraints: edge.constraints,
                   main_version: main)
    end

    def prerelease_floor?(edge)
      Gem::Requirement.new(*edge.constraints).requirements
        .any? { |_, version| version.prerelease? }
    end

    def unreleased(gem)
      node = @graph.nodes[gem]
      return unless node

      if node.ahead_by.to_i.positive?
        Unreleased.new(gem: gem, ahead_by: node.ahead_by,
                       main_version: node.main_version)
      elsif node.released.nil? && node.main_version
        Unreleased.new(gem: gem, ahead_by: nil,
                       main_version: node.main_version)
      end
    end
  end
end
