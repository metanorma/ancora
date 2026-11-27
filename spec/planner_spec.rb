# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ancora::Planner do
  # A real-shaped slice of the metanorma fleet: plugin depends on ea,
  # standoc depends on plugin, cli depends on standoc and the flavors.
  let(:network) do
    {
      "lutaml/ea" => { "name" => "ea", "main_version" => "0.6.41",
                       "deps" => [{ "name" => "xmi", "constraints" => ["~> 0.7"] }] },
      "lutaml/xmi" => { "name" => "xmi", "main_version" => "0.7.6",
                        "deps" => [{ "name" => "lutaml-model", "constraints" => [] }] },
      "lutaml/lutaml-model" => { "name" => "lutaml-model",
                                 "main_version" => "0.8.88", "deps" => [] },
      "metanorma/metanorma-plugin-lutaml" => {
        "name" => "metanorma-plugin-lutaml", "main_version" => "0.7.54",
        "deps" => [{ "name" => "ea", "constraints" => [">= 0.6.41"] }]
      },
      "metanorma/metanorma-standoc" => {
        "name" => "metanorma-standoc", "main_version" => "3.5.0",
        "deps" => [{ "name" => "metanorma-plugin-lutaml", "constraints" => ["~> 0.7.31"] }]
      },
      "metanorma/metanorma-cli" => {
        "name" => "metanorma-cli", "main_version" => "1.17.0",
        "deps" => [{ "name" => "metanorma-standoc", "constraints" => ["~> 3.5.0"] }]
      },
    }
  end

  let(:delta) do
    {
      "lutaml/ea" => { "gem" => "ea", "main_version" => "0.6.42",
                       "released" => "0.6.41", "ahead_by" => 2 },
      "lutaml/xmi" => { "gem" => "xmi", "main_version" => "0.7.6",
                        "released" => "0.7.6", "ahead_by" => 0 },
      "metanorma/metanorma-standoc" => { "gem" => "metanorma-standoc",
                                         "released" => "3.5.0", "ahead_by" => 65 },
    }
  end

  let(:graph) { Ancora::Graph.from_data(network, delta) }

  it "plans full waves leaves-first from drifted gems only" do
    # plugin-lutaml and cli carry no drift (0.7.54 / 1.17.0 are out). Waves
    # level over the projected set: standoc's only in-set dependency is none
    # (its direct dep plugin-lutaml is already released), so it shares wave 1
    # with ea - a gem releases once its UNRELEASED dependencies come out
    waves = described_class.new(graph).plan
    expect(waves).to eq([["ea", "metanorma-standoc"]])
  end

  it "scopes a repair wave from seeds to the affected subgraph" do
    waves = described_class.new(graph).plan(scope: :scoped, seeds: ["ea"])
    expect(waves.flatten).to include("ea", "metanorma-plugin-lutaml",
                                     "metanorma-standoc", "metanorma-cli")
    expect(waves.flatten).not_to include("xmi")
  end

  it "flags floorless edges" do
    expect(graph.floorless_edges.map(&:to)).to eq(["lutaml-model"])
  end

  describe "semantic planning" do
    def scoped_chain_waves(seed, semantic:)
      chain = FleetFixture.load_chain(FleetFixture::METANORMA_CHAIN)
      fleet = Ancora::Graph.from_data(FleetFixture::NETWORK,
                                      FleetFixture::DELTA)
      described_class.new(fleet, chain: chain)
        .plan(scope: :scoped, seeds: [seed], semantic: semantic)
    end

    # A ten-deep line g0 <- g1 <- ... <- g9 (gN depends on g(N-1)), every
    # gem ahead of its release. Structural planning needs ten waves. Only
    # two edges really force an order: g1 -> g0 has no floor, and g2 -> g1
    # floors a version not yet released. The rest carry floors the
    # released dependency already satisfies.
    let(:graph) do
      network = {}
      delta = {}
      10.times do |i|
        deps = if i.zero?
                 []
               elsif i == 1
                 [{ "name" => "g0", "constraints" => [] }]
               elsif i == 2
                 [{ "name" => "g1", "constraints" => [">= 1.1.0"] }]
               else
                 [{ "name" => "g#{i - 1}", "constraints" => [">= 1.0.0"] }]
               end
        network["o/g#{i}"] = { "name" => "g#{i}", "main_version" => "1.1.0",
                               "deps" => deps }
        delta["o/g#{i}"] = { "gem" => "g#{i}", "main_version" => "1.1.0",
                             "released" => "1.0.0", "ahead_by" => 3 }
      end
      Ancora::Graph.from_data(network, delta)
    end

    it "keeps the terminus alone in the last wave when satisfied edges drop" do
      waves = scoped_chain_waves("ea", semantic: true)
      expect(waves.last).to eq(["metanorma-cli"])
      expect(waves.flatten).to match_array(
        scoped_chain_waves("ea", semantic: false).flatten,
      )
    end

    it "still rejects a terminus split over dependent units" do
      network = {
        "r/a" => { "name" => "a", "main_version" => "1.0.0",
                   "deps" => [{ "name" => "b", "constraints" => [] }] },
        "r/b" => { "name" => "b", "main_version" => "1.0.0", "deps" => [] },
        "r/c" => { "name" => "c", "main_version" => "1.0.0", "deps" => [] },
      }
      delta = %w[a b c].to_h do |g|
        ["r/#{g}", { "gem" => g, "released" => "0.9.0", "ahead_by" => 1 }]
      end
      chain = FleetFixture.load_chain(<<~YAML)
        name: split
        inventory:
          gems: [a, b, c]
        terminus: [a, b]
      YAML
      planner = described_class.new(Ancora::Graph.from_data(network, delta),
                                    chain: chain)
      expect { planner.plan(semantic: true) }
        .to raise_error(/terminus .* must be alone/)
    end

    it "does not report a floorless edge inside one release unit" do
      network = {
        "r/mono" => { "name" => "a", "main_version" => "1.0.0",
                      "deps" => [{ "name" => "b", "constraints" => [] }] },
        "r/b" => { "name" => "b", "main_version" => "1.0.0", "deps" => [] },
      }
      delta = {
        "r/mono" => { "gem" => "a", "released" => "0.9.0", "ahead_by" => 1 },
        "r/b" => { "gem" => "b", "released" => "0.9.0", "ahead_by" => 1 },
      }
      graph = Ancora::Graph.from_data(network, delta)
      chain = FleetFixture.load_chain(<<~YAML)
        name: mono
        inventory:
          gems: [a, b]
        monorepos:
          r/mono: [a, b]
      YAML
      planner = described_class.new(graph, chain: chain)
      planner.plan(semantic: true)
      expect(planner.floorless_binding(%w[a b])).to be_empty
    end

    it "needs ten structural waves for the line" do
      expect(described_class.new(graph).plan.size).to eq(10)
    end

    it "cuts the line to three waves when only binding edges order it" do
      waves = described_class.new(graph).plan(semantic: true)
      expect(waves).to eq([
                            %w[g0 g3 g4 g5 g6 g7 g8 g9],
                            %w[g1],
                            %w[g2],
                          ])
    end

    it "keeps every drifted gem in the plan" do
      structural = described_class.new(graph).plan.flatten
      semantic = described_class.new(graph).plan(semantic: true).flatten
      expect(semantic).to match_array(structural)
    end

    it "reports the floorless edges that still order the plan" do
      planner = described_class.new(graph)
      gems = planner.plan(semantic: true).flatten
      expect(planner.floorless_binding(gems).map { |e| [e.from, e.to] })
        .to eq([%w[g1 g0]])
    end

    it "treats a floor the released dependency does not satisfy as ordering" do
      waves = described_class.new(graph).plan(semantic: true)
      expect(waves.index { |w| w.include?("g1") })
        .to be < waves.index { |w| w.include?("g2") }
    end

    it "treats an unreleased dependency as ordering" do
      network = {
        "o/a" => { "name" => "a", "main_version" => "0.1.0",
                   "deps" => [{ "name" => "b", "constraints" => [">= 0.1"] }] },
        "o/b" => { "name" => "b", "main_version" => "0.1.0", "deps" => [] },
      }
      delta = {
        "o/a" => { "gem" => "a", "released" => nil, "ahead_by" => 1 },
        "o/b" => { "gem" => "b", "released" => nil, "ahead_by" => 1 },
      }
      g = Ancora::Graph.from_data(network, delta)
      expect(described_class.new(g).plan(semantic: true)).to eq([["b"], ["a"]])
    end

    it "leaves the default plan unchanged" do
      planner = described_class.new(graph)
      planner.plan(semantic: true)
      expect(planner.plan.size).to eq(10)
    end

    it "keeps release units whole and the terminus last in chain mode" do
      chain = FleetFixture.load_chain(FleetFixture::METANORMA_CHAIN)
      fleet = Ancora::Graph.from_data(FleetFixture::NETWORK, FleetFixture::DELTA)
      structural = described_class.new(fleet, chain: chain).plan
      semantic = described_class.new(fleet, chain: chain).plan(semantic: true)
      expect(semantic.flatten).to match_array(structural.flatten)
      expect(semantic.size).to be <= structural.size
      expect(semantic.flatten).to include("metanorma-standoc")
    end

    def drifted_pair(constraints)
      network = {
        "r1" => { "name" => "a", "main_version" => "1.1.0",
                  "deps" => [{ "name" => "b", "constraints" => constraints }] },
        "r2" => { "name" => "b", "main_version" => "1.1.0", "deps" => [] },
      }
      delta = {
        "r1" => { "gem" => "a", "released" => "1.0.0", "ahead_by" => 1 },
        "r2" => { "gem" => "b", "released" => "1.0.0", "ahead_by" => 1 },
      }
      Ancora::Graph.from_data(network, delta)
    end

    it "rejects constraints that are not a list of requirement strings" do
      expect { described_class.new(drifted_pair(5)).plan(semantic: true) }
        .to raise_error(ArgumentError, /list of requirement strings/)
    end

    it "names the edge when a constraint is not a requirement" do
      planner = described_class.new(drifted_pair(["bogus"]))
      expect { planner.plan(semantic: true) }
        .to raise_error(ArgumentError, /a -> b: illformed constraints/)
    end
  end
end
