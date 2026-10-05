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
end
