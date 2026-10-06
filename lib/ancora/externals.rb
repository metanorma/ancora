# frozen_string_literal: true

module Ancora
  # The cross-chain handshake check: dependency edges from a chain's
  # inventory into EXTERNAL gems (other chains' or third-party). The
  # promote-gate requires external FINALS - nothing promotes against
  # another chain's prerelease - so a floor satisfied by no final is
  # the release-request case (the ea 0.6.41 story): file the request on
  # the external chain's repo and gate on its rubygems oracle.
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
        .uniq { |e| [e.to, e.constraints] }
        .map { |e| finding(e) }.sort_by { |f| [f.gem, f.from] }
    end

    private

    def finding(edge)
      requirement = Gem::Requirement.new(*edge.constraints)
      finals = @oracle.finals(edge.to)
      best = finals.find { |v| requirement.satisfied_by?(Gem::Version.new(v)) }
      Finding.new(gem: edge.to, from: edge.from, constraints: edge.constraints,
                  latest_final: best || finals.first,
                  status: best ? :satisfied : :awaiting_release)
    end
  end
end
