# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Ancora::Planner, "chain scoped" do
  let(:graph) { Ancora::Graph.from_data(FleetFixture::NETWORK, FleetFixture::DELTA) }

  def chain(yaml)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "chain.yml")
      File.write(path, yaml)
      yield Ancora::Chain.load(path)
    end
  end

  it "plans a repair wave seeded at an external-chain gem, terminus alone" do
    # ea belongs to the lutaml chain; the metanorma repair wave covers
    # only its in-chain dependents, from plugin-lutaml upward to the cli
    chain(FleetFixture::METANORMA_CHAIN) do |c|
      waves = described_class.new(graph, chain: c)
        .plan(scope: :scoped, seeds: ["ea"])
      expect(waves).to eq(
        [["metanorma-plugin-lutaml"], ["metanorma-standoc"], ["metanorma-cli"]],
      )
    end
  end

  it "plans the metanorma full wave over drift inside the inventory only" do
    chain(FleetFixture::METANORMA_CHAIN) do |c|
      waves = described_class.new(graph, chain: c).plan
      expect(waves).to eq([["metanorma-document"], ["metanorma-standoc"]])
    end
  end

  it "keeps the relaton monorepo pair in one wave, terminus expanded" do
    chain(FleetFixture::RELATON_CHAIN) do |c|
      waves = described_class.new(graph, chain: c).plan
      expect(waves).to eq([["pubid"], ["relaton", "relaton-cli"]])
    end
  end

  it "plans the glossarist chain as a single-gem wave" do
    chain(FleetFixture::GLOSSARIST_CHAIN) do |c|
      expect(described_class.new(graph, chain: c).plan).to eq([["glossarist"]])
    end
  end

  it "plans the lutaml fan with no terminus declared" do
    chain(FleetFixture::LUTAML_CHAIN) do |c|
      waves = described_class.new(graph, chain: c).plan
      expect(waves).to eq([["xmi"], ["ea"]])
    end
  end

  it "plans nothing when a scoped wave misses the inventory entirely" do
    chain(FleetFixture::METANORMA_CHAIN) do |c|
      expect(described_class.new(graph, chain: c)
        .plan(scope: :scoped, seeds: ["cimas"])).to eq([])
    end
  end

  it "raises when a terminus gem lands before the final wave" do
    yaml = FleetFixture::METANORMA_CHAIN.sub("terminus: [metanorma-cli]",
                                             "terminus: [metanorma-standoc]")
    chain(yaml) do |c|
      expect do
        described_class.new(graph, chain: c).plan(scope: :scoped, seeds: ["ea"])
      end
        .to raise_error(/metanorma-standoc.*final wave/m)
    end
  end

  it "raises when a gem outside the terminus unit shares the final wave" do
    # the same relaton chain but WITHOUT the monorepo declaration: relaton
    # rides along as a foreign singleton in the terminus wave
    yaml = <<~YAML
      name: relaton
      inventory:
        orgs: [relaton, pubid]
        gems: [relaton]
      terminus: [relaton-cli]
    YAML
    chain(yaml) do |c|
      expect do
        described_class.new(graph, chain: c)
          .plan(scope: :scoped, seeds: %w[relaton relaton-cli])
      end
        .to raise_error(/non-terminus gems/)
    end
  end
end
