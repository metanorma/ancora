# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Ancora::GateLock do
  let(:graph) { Ancora::Graph.from_data(FleetFixture::NETWORK, FleetFixture::DELTA) }

  def chain(yaml)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "chain.yml")
      File.write(path, yaml)
      yield Ancora::Chain.load(path)
    end
  end

  it "pins the whole metanorma chain inventory at exact released versions" do
    chain(FleetFixture::METANORMA_CHAIN) do |c|
      expect(described_class.new(c, graph).pins).to eq(
        "metanorma-cli" => "1.17.0",
        "metanorma-document" => "0.5.1",
        "metanorma-plugin-lutaml" => "0.7.54",
        "metanorma-standoc" => "3.5.0",
      )
    end
  end

  it "overrides pins with the wave's candidate versions" do
    chain(FleetFixture::METANORMA_CHAIN) do |c|
      pins = described_class.new(c, graph)
        .pins("metanorma-document" => "0.5.2.pre.alpha.1",
              "metanorma-standoc" => "3.5.1.pre.alpha.1")
      expect(pins["metanorma-document"]).to eq "0.5.2.pre.alpha.1"
      expect(pins["metanorma-standoc"]).to eq "3.5.1.pre.alpha.1"
      expect(pins["metanorma-cli"]).to eq "1.17.0"
    end
  end

  it "emits a Gemfile pinning the whole chain, candidates and floors alike" do
    chain(FleetFixture::METANORMA_CHAIN) do |c|
      gemfile = described_class.new(c, graph)
        .gemfile("metanorma-document" => "0.5.2.pre.alpha.1")
      expect(gemfile).to include('gem "metanorma-document", "0.5.2.pre.alpha.1"')
      expect(gemfile).to include('gem "metanorma-cli", "1.17.0"')
      expect(gemfile).to include('gem "metanorma-plugin-lutaml", "0.7.54"')
      expect(gemfile).not_to include("metanorma-standoc\", \"3.5.1\"")
    end
  end

  it "pins both gems of the relaton monorepo unit, flagging unversioned members" do
    chain(FleetFixture::RELATON_CHAIN) do |c|
      lock = described_class.new(c, graph)
      expect(lock.pins["relaton-cli"]).to eq "3.0.0.pre.alpha.4"
      expect(lock.pins["pubid"]).to eq "2.0.0.pre.alpha.27"
      expect(lock.pins).not_to have_key("relaton")
      expect(lock.gemfile).to include("# relaton: no version on record")
    end
  end

  it "pins the single-gem glossarist chain" do
    chain(FleetFixture::GLOSSARIST_CHAIN) do |c|
      expect(described_class.new(c, graph).pins).to eq("glossarist" => "2.14.1")
    end
  end
end
