# frozen_string_literal: true

module Ancora
  # The dependency graph of a gem fleet, loaded from the collector's
  # data: network.json (per-repo gemspecs: name, main version, deps with
  # constraints) and delta.json (latest release, main-ahead count).
  # Nodes are gems; an edge A -> B means A depends on B.
  class Graph
    Edge = Struct.new(:from, :to, :constraints, keyword_init: true)
    Node = Struct.new(:name, :repo, :main_version, :released, :ahead_by,
                      keyword_init: true)

    attr_reader :nodes, :edges

    # Edges whose target has no node in the collected data (external
    # chains and third-party gems the scan does not cover). Kept apart
    # so wave planning and drift stay scoped to the collected fleet,
    # while the externals check can still see the floors.
    def external_edges
      @external_edges ||= []
    end

    def self.load(network_path, delta_path = nil)
      network = JSON.parse(File.read(network_path))
      delta = delta_path && File.file?(delta_path) ? JSON.parse(File.read(delta_path)) : {}
      from_data(network, delta)
    end

    def self.from_data(network, delta)
      delta_by_gem = {}
      delta.each_value { |v| delta_by_gem[v["gem"]] = v }

      nodes = {}
      network.each do |repo, g|
        next unless g["name"]

        d = delta_by_gem[g["name"]] || {}
        nodes[g["name"]] = Node.new(
          name: g["name"], repo: d["repo"] || repo,
          main_version: d["main_version"] || g["main_version"],
          released: d["released"], ahead_by: d["ahead_by"]
        )
      end

      edges = []
      external = []
      network.each_value do |g|
        next unless g["name"]

        (g["deps"] || []).each do |dep|
          target = nodes[dep["name"]]
          edge = Edge.new(from: g["name"], to: dep["name"],
                          constraints: dep["constraints"])
          target ? (edges << edge) : (external << edge)
        end
      end
      new(nodes, edges, external)
    end

    def initialize(nodes, edges, external_edges = [])
      @nodes = nodes
      @edges = edges
      @external_edges = external_edges
      rebuild_indices
    end

    def dependents_of(gem)
      @dependents[gem] || []
    end

    def dependencies_of(gem)
      @dependencies[gem] || []
    end

    def floorless_edges
      edges.select { |e| e.constraints.nil? || e.constraints.empty? }
    end

    private

    def rebuild_indices
      @dependents = Hash.new { |h, k| h[k] = [] }
      @dependencies = Hash.new { |h, k| h[k] = [] }
      edges.each do |e|
        @dependents[e.to] << e.from
        @dependencies[e.from] << e.to
      end
      @dependents.each_value(&:uniq!)
      @dependencies.each_value(&:uniq!)
    end
  end
end
