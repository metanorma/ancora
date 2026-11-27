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
  #
  # Semantic planning (`semantic: true`) orders only by edges that force
  # a release order. An edge A -> B binds when A cannot ship without a
  # new B: its floor excludes B's latest release (A's main already needs
  # unreleased B), or it has no floor at all (nothing proves A works
  # with the released B, so the edge stays ordering until a floor is
  # pinned). An edge whose floor the released B already satisfies does
  # not bind, so A and B may share a wave. The floorless remainder is
  # exposed by #floorless_binding: each is a one-line floor edit away
  # from dropping out of the order.
  class Planner
    def initialize(graph, chain: nil)
      @graph = graph
      @chain = chain
    end

    def plan(scope: :full, seeds: [], semantic: false)
      @semantic = semantic
      gems = scope == :scoped ? affected_from(seeds) : drifted
      return waves(gems) unless @chain

      planned = gems & @chain.inventory(@graph)
      unit_waves(planned).tap { |w| assert_terminus(w) }
    end

    # Floorless edges that still bind the order among the given gems:
    # the depth semantic planning cannot remove until a floor is pinned.
    def floorless_binding(gems)
      @graph.floorless_edges.select do |e|
        gems.include?(e.from) && gems.include?(e.to) &&
          binding_edge?(e) && !same_unit?(e)
      end
    end

    private

    def dependencies_of(gem)
      return @graph.dependencies_of(gem) unless @semantic

      @graph.edges.select { |e| e.from == gem && binding_edge?(e) }
        .map(&:to).uniq
    end

    # a monorepo's gems always share a wave: an edge inside one unit
    # orders nothing
    def same_unit?(edge)
      return false unless @chain

      @chain.units(@graph).any? do |u|
        u.gems.include?(edge.from) && u.gems.include?(edge.to)
      end
    end

    def binding_edge?(edge)
      requirement = requirement_for(edge)
      return true unless requirement

      released = @graph.nodes[edge.to]&.released
      return true if released.nil?

      !requirement.satisfied_by?(Gem::Version.new(released))
    end

    # nil for an edge with no floor
    def requirement_for(edge)
      constraints = edge.constraints
      return if constraints.nil?
      unless constraints.is_a?(Array) && constraints.all?(String)
        raise ArgumentError, "#{edge.from} -> #{edge.to}: constraints must " \
                             "be a list of requirement strings"
      end
      return if constraints.empty?

      Gem::Requirement.new(*constraints)
    rescue Gem::Requirement::BadRequirementError
      raise ArgumentError, "#{edge.from} -> #{edge.to}: illformed constraints " \
                           "#{constraints.inspect}"
    end

    def waves(gems)
      set = gems.to_h { |g| [g, true] }
      placed = {}
      levels = []
      until set.empty?
        ready = set.keys.select do |g|
          (dependencies_of(g) & set.keys).empty?
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
            dependencies_of(g).any? do |d|
              dep = gem_unit[d]
              dep && dep != u && remaining.include?(dep)
            end
          end
        end
        ready = hold_terminus(ready, remaining)
        break if ready.empty? # cycle: emit the remainder as one wave

        levels << ready.flat_map(&:gems).sort
        ready.each { |u| remaining.delete(u) }
      end
      levels << remaining.flat_map(&:gems).sort unless remaining.empty?
      levels
    end

    # The terminus pins the whole chain, so semantic planning, which
    # drops satisfied edges, still places it alone after every other
    # unit.
    def hold_terminus(ready, remaining)
      return ready unless @semantic && @chain.terminus(@graph)

      terminus = @chain.terminus(@graph)
      last, rest = ready.partition { |u| (u.gems & terminus).any? }
      others = remaining.reject { |u| (u.gems & terminus).any? }
      last.empty? || others.empty? ? ready : rest
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
