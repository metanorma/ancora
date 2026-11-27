# frozen_string_literal: true

module Ancora
  # Automated floor-pin fixing: turns the drift classes that corrupt a
  # dependency floor into concrete gemspec edits. Three classes are
  # fixable from the collector data alone, always against the dependency's
  # RELEASED final (a floor never names an unreleased main or a prerelease):
  #
  # * floorless: no constraint at all, becomes ">= released"
  # * prerelease floor: each prerelease clause becomes ">= released"
  # * stale pin: a floor that excludes the dependency's main version
  #   becomes ">= released"
  #
  # An edge whose dependency has no released final cannot be fixed; it is
  # reported as skipped with the reason. Planning is pure data; applying
  # edits only gemspec files under a local checkout root. Nothing here
  # commits, pushes, tags or releases.
  class FloorFixer
    Fix = Struct.new(:from, :to, :kind, :constraints, :proposed,
                     keyword_init: true)
    Skip = Struct.new(:from, :to, :kind, :constraints, :reason,
                      keyword_init: true)
    Plan = Struct.new(:fixes, :skipped, keyword_init: true)

    LOWER_OPS = [">=", ">", "~>", "="].freeze

    def initialize(graph, chain: nil)
      @graph = graph
      @chain = chain
    end

    def plan
      fixes = []
      skipped = []
      scoped_edges.each do |edge|
        outcome = plan_edge(edge)
        next unless outcome

        (outcome.is_a?(Fix) ? fixes : skipped) << outcome
      end
      Plan.new(fixes: fixes, skipped: skipped)
    end

    private

    def plan_edge(edge)
      kind = classify(edge)
      kind && propose(edge, kind)
    rescue ArgumentError => e
      skip(edge, :unreadable, "constraints cannot be read: #{e.message}")
    end

    def scoped_edges
      return @graph.edges unless @chain

      inventory = @chain.inventory(@graph)
      @graph.edges.select { |e| inventory.include?(e.from) }
    end

    def classify(edge)
      constraints = Array(edge.constraints)
      return :floorless if constraints.empty?
      return :prerelease_floor if prerelease_clauses(constraints).any?

      :stale_pin if stale?(edge, constraints)
    end

    def propose(edge, kind)
      constraints = Array(edge.constraints)
      released = final_release(edge.to)
      reason = if released
                 unsafe_reason(kind, constraints, released)
               else
                 "#{edge.to} has no released final"
               end
      return skip(edge, kind, reason) if reason

      Fix.new(from: edge.from, to: edge.to, kind: kind,
              constraints: constraints,
              proposed: proposal(kind, constraints, released))
    end

    # a proposal must still admit the released final, and a stale-pin fix
    # may only raise a floor, never lower one the owner set above released
    def unsafe_reason(kind, constraints, released)
      version = Gem::Version.new(released)
      if kind == :prerelease_floor && !covers_prerelease?(constraints, released)
        return "released #{released} is older than the prerelease floor"
      end
      if kind == :stale_pin && raises_above?(constraints, version)
        return "floor #{lower_bound(constraints)} is above released #{released}"
      end

      proposed = proposal(kind, constraints, released)
      return if Gem::Requirement.new(*proposed).satisfied_by?(version)

      "proposal #{proposed.join(', ')} excludes released #{released}"
    end

    # an existing floor the released final does not clear: above it, or a
    # strict "> x" at or above it
    def raises_above?(constraints, version)
      constraints.map { |c| Gem::Requirement.parse(c) }.any? do |op, bound|
        (op == ">" && bound >= version) ||
          (LOWER_OPS.include?(op) && bound > version)
      end
    end

    def lower_bound(constraints)
      bounds = constraints.map { |c| Gem::Requirement.parse(c) }
        .filter_map { |op, version| version if LOWER_OPS.include?(op) }
      bounds.max || Gem::Version.new("0")
    end

    def proposal(kind, constraints, released)
      floor = ">= #{released}"
      kept = constraints.reject do |c|
        kind == :prerelease_floor ? prerelease_clause?(c) : lower_clause?(c)
      end
      (kept + [floor]).uniq
    end

    def lower_clause?(clause)
      LOWER_OPS.include?(Gem::Requirement.parse(clause).first)
    end

    def covers_prerelease?(constraints, released)
      prerelease_clauses(constraints).all? do |_, version|
        Gem::Version.new(released) >= version.release
      end
    end

    def stale?(edge, constraints)
      main = @graph.nodes[edge.to]&.main_version
      return false if main.nil? || Gem::Version.new(main).prerelease?

      !Gem::Requirement.new(*constraints)
        .satisfied_by?(Gem::Version.new(main))
    end

    def prerelease_clauses(constraints)
      constraints.map { |c| Gem::Requirement.parse(c) }
        .select { |_, version| version.prerelease? }
    end

    def prerelease_clause?(constraint)
      Gem::Requirement.parse(constraint).last.prerelease?
    end

    def final_release(gem)
      released = @graph.nodes[gem]&.released
      return if released.nil? || Gem::Version.new(released).prerelease?

      released
    end

    def skip(edge, kind, reason)
      Skip.new(from: edge.from, to: edge.to, kind: kind,
               constraints: Array(edge.constraints), reason: reason)
    end
  end
end
