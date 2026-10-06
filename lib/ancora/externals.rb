# frozen_string_literal: true

module Ancora
  # The cross-chain handshake check: dependency edges from a chain's
  # inventory into EXTERNAL gems (other chains' or third-party). The
  # promote-gate requires external FINALS - nothing promotes against
  # another chain's prerelease - so a floor satisfied by no final is
  # the release-request case (the ea 0.6.41 story): file the request on
  # the external chain's repo and gate on its rubygems oracle.
  #
  # Findings merge every edge onto the same external gem into ONE
  # requirement - the union all dependents impose, exactly what bundler
  # resolves - so individually satisfiable floors that conflict in the
  # union surface as awaiting release.
  class Externals
    Finding = Struct.new(:gem, :from, :constraints, :latest_final, :status,
                         keyword_init: true)

    def initialize(graph, chain:, oracle:)
      @graph = graph
      @chain = chain
      @oracle = oracle
    end

    def check
      inventory = @chain.inventory(@graph)
      (@graph.edges + @graph.external_edges)
        .select do |e|
          inventory.include?(e.from) && !inventory.include?(e.to) &&
            !e.constraints.empty?
        end
        .group_by(&:to)
        .map { |gem, edges| finding(gem, edges) }.sort_by(&:gem)
    end

    private

    def finding(gem, edges)
      constraints = edges.flat_map(&:constraints).uniq
      requirement = Gem::Requirement.new(*constraints)
      finals = @oracle.finals(gem)
      best = finals.find { |v| requirement.satisfied_by?(Gem::Version.new(v)) }
      Finding.new(gem: gem, from: edges.map(&:from).uniq.sort,
                  constraints: constraints,
                  latest_final: best || finals.first,
                  status: best ? :satisfied : :awaiting_release)
    end
  end
end
