# frozen_string_literal: true

module Ancora
  # Plans release waves: antichains of the dependency graph, leaves
  # first, terminus last. Two scopes:
  #
  #   full   - every gem with release drift (main ahead of its latest
  #            release), the default fleet wave; and
  #   scoped - the transitively affected subgraph upward from seed gems
  #            (a defect or a feature), the repair-wave case.
  class Planner
    def initialize(graph)
      @graph = graph
    end

    def plan(scope: :full, seeds: [])
      gems = scope == :scoped ? affected_from(seeds) : drifted
      waves(gems)
    end

    private

    # Kahn levels over the managed subgraph: a gem's level sits one past
    # the deepest managed dependency it carries.
    def waves(gems)
      set = gems.to_h { |g| [g, true] }
      placed = {}
      levels = []
      until set.empty?
        ready = set.keys.select do |g|
          (@graph.dependencies_of(g) & set.keys).empty?
        end
        break if ready.empty? # cycle: emit the remainder as one wave

        levels << ready.sort
        ready.each { |g| placed[g] = true }
        set.delete_if { |g, _| placed[g] }
      end
      levels << set.keys.sort unless set.empty?
      levels
    end

    def drifted
      @graph.nodes.values.select { |n| n.ahead_by.to_i.positive? }.map(&:name)
    end

    def affected_from(seeds)
      seen = {}
      frontier = seeds.dup
      until frontier.empty?
        gem = frontier.pop
        next if seen[gem]

        seen[gem] = true
        frontier.concat(@graph.dependents_of(gem))
      end
      seen.keys
    end
  end
end
