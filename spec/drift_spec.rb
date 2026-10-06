# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Ancora::Drift do
  let(:graph) { Ancora::Graph.from_data(FleetFixture::NETWORK, FleetFixture::DELTA) }

  def chain(yaml)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "chain.yml")
      File.write(path, yaml)
      yield Ancora::Chain.load(path)
    end
  end

  it "reports floorless sibling edges" do
    pairs = described_class.new(graph).report.floorless.map do |e|
      [e.from, e.to]
    end
    expect(pairs).to contain_exactly(
      %w[lutaml lutaml-model], %w[lutaml lutaml-uml],
      %w[lutaml-model canon], %w[xmi lutaml-model]
    )
  end

  it "reports stale pins: constraints that exclude the dependency's main" do
    pins = described_class.new(graph).report.stale_pins
    expect(pins.map { |s| [s.from, s.to] }).to contain_exactly(
      %w[metanorma-document glossarist], %w[isodoc isodoc-i18n]
    )
    glossarist = pins.find { |s| s.to == "glossarist" }
    expect(glossarist.main_version).to eq "2.15.0"
  end

  it "does not report satisfied pessimistic pins as stale" do
    expect(described_class.new(graph).report.stale_pins)
      .not_to include(an_object_having_attributes(from: "metanorma-standoc"))
  end

  it "reports floors that reference prereleases (the lint class)" do
    floors = described_class.new(graph).report.prerelease_floors
    expect(floors.map { |e| [e.from, e.to] }).to eq([%w[relaton-cli pubid]])
  end

  it "reports unreleased main: drift and never-released gems" do
    unreleased = described_class.new(graph).report.unreleased
    document = unreleased.find { |u| u.gem == "metanorma-document" }
    expect(document.ahead_by).to eq 131
    expect(unreleased.map(&:gem)).to include("xseed", "isodoc")
    expect(unreleased.find { |u| u.gem == "xseed" }.ahead_by).to be_nil
  end

  it "scopes the report to a chain's inventory" do
    chain(FleetFixture::METANORMA_CHAIN) do |c|
      rep = described_class.new(graph, chain: c).report
      expect(rep.floorless).to be_empty
      expect(rep.stale_pins.map(&:from)).to eq(["metanorma-document"])
      expect(rep.prerelease_floors).to be_empty
      expect(rep.unreleased.map(&:gem)).to eq(
        %w[metanorma-document metanorma-standoc],
      )
    end
  end
end
