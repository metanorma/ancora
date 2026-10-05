# frozen_string_literal: true

module Ancora
  # Plans release waves: antichains of the dependency graph, leaves
  # first, terminus last. Two scopes:
  #
  #   full   - every gem with release drift (main ahead of its latest
  #            release), the default fleet wave; and
  #   scoped - the transitively affected subgraph upward from seed gems
  #            (a defect or a feature), the repair-wave case.
  #
  # With a chain, planning runs inside the chain's inventory and over
  # its release units: a monorepo's gems never split across waves (the
  # wave versions the repo). The configured terminus must be alone in
  # the final wave whenever the plan reaches it.
  class Planner
    def initialize(graph, chain: nil)
      @graph = graph
      @chain = chain
    end

    def plan(scope: :full, seeds: [])
      gems = scope == :scoped ? affected_from(seeds) : drifted
      return waves(gems) unless @chain

      planned = gems & @chain.inventory(@graph)
      unit_waves(planned).tap { |w| assert_terminus(w) }
    end

    private

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

    def unit_waves(planned_gems)
      units = @chain.units(@graph)
      gem_unit = units.each_with_object({}) do |u, h|
        u.gems.each do |g|
          h[g] = u
        end
      end
      remaining = units.select { |u| (u.gems & planned_gems).any? }
      levels = []
      until remaining.empty?
        ready = remaining.select do |u|
          u.gems.none? do |g|
            @graph.dependencies_of(g).any? do |d|
              dep = gem_unit[d]
              dep && dep != u && remaining.include?(dep)
            end
          end
        end
        break if ready.empty? # cycle: emit the remainder as one wave

        levels << ready.flat_map(&:gems).sort
        ready.each { |u| remaining.delete(u) }
      end
      levels << remaining.flat_map(&:gems).sort unless remaining.empty?
      levels
    end

    def assert_terminus(waves)
      terminus = @chain.terminus(@graph)
      return if terminus.nil? || waves.empty?

      planned_terminus = terminus & waves.flatten
      return if planned_terminus.empty?

      waves[0...-1].each_with_index do |wave, i|
        clash = wave & terminus
        unless clash.empty?
          raise "chain #{@chain.name}: terminus #{clash.join(', ')} must be alone " \
                "in the final wave (appears in wave #{i + 1} of #{waves.size})"
        end
      end
      extras = waves.last - terminus
      return if extras.empty?

      raise "chain #{@chain.name}: final wave contains non-terminus gems: " \
            "#{extras.join(', ')} (terminus: #{terminus.join(', ')})"
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
