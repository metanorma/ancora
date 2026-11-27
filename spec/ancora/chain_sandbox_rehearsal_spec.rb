# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ancora::Chain do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:chain) do
    described_class.load(File.join(root, "examples/sandbox.chain.yml"))
  end
  let(:graph) do
    fixture = File.join(root, "examples/sandbox/fixture")
    Ancora::Graph.load(File.join(fixture, "network.json"),
                       File.join(fixture, "delta.json"))
  end

  it "loads the sandbox chain with every key the runtime reads" do
    expect(chain.name).to eq "metanorma-sandbox"
    expect(chain.orgs).to eq ["metanorma-sandbox"]
    expect(chain.gate_commands).to eq ["bundle exec rspec"]
    expect(chain.canary_commands).to eq ["bin/compile-plateau-doc.sh"]
    expect(chain.promote_approval).to eq "manual"
    expect(chain.terminus(graph)).to eq ["metanorma-cli"]
  end

  it "plans a non-empty dry run over the labelled fixture" do
    waves = Ancora::Planner.new(graph, chain: chain).plan
    expect(waves).to eq [["metanorma-standoc"], ["metanorma-cli"]]
  end
end
