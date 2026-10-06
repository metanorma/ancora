# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ancora::GateRecipe do
  let(:graph) { Ancora::Graph.from_data(FleetFixture::NETWORK, FleetFixture::DELTA) }

  it "renders the gate: lock, per-gem suites, and the canary" do
    chain = FleetFixture.load_chain(FleetFixture::METANORMA_CHAIN)
    pins = {
      "metanorma-document" => "0.5.2.pre.alpha.1",
      "metanorma-standoc" => "3.5.1.pre.alpha.1",
    }
    recipe = described_class.new(chain, graph).build(pins)

    expect(recipe.lockfile).to include('gem "metanorma-document", "0.5.2.pre.alpha.1"')
    expect(recipe.lockfile).to include('gem "metanorma-cli", "1.17.0"')
    expect(recipe.suites.map(&:gem)).to eq(%w[metanorma-document
                                              metanorma-standoc])
    expect(recipe.suites.first.repo).to eq "metanorma/metanorma-document"
    expect(recipe.suites.first.commands).to eq(["bundle exec rspec"])
    expect(recipe.canary).to eq(["bundle exec rake site"])
    expect(recipe.corpora).to be_empty
  end

  it "includes the corpora gating the attempt's gems" do
    chain = FleetFixture.load_chain(FleetFixture::METANORMA_CHAIN)
    pins = {
      "metanorma-iso" => "3.5.1.pre.alpha.1",
      "metanorma-cli" => "1.18.0.pre.alpha.1",
    }
    recipe = described_class.new(chain, graph).build(pins)
    expect(recipe.corpora.map(&:repo)).to eq(
      ["metanorma/mn-samples-iso", "metanorma/mn-samples-iso-private",
       "metanorma/mn-samples-jis"],
    )
    jis = recipe.corpora.find { |e| e.repo == "metanorma/mn-samples-jis" }
    expect(jis.gems).to eq(["metanorma-cli"])
    expect(jis.budget).to eq 240
  end
end
