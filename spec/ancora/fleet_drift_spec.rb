# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ancora::FleetDrift do
  let(:oracle_class) do
    Struct.new(:tagged) do
      def tag_status(repo, version)
        return :unknown if repo == "unreachable"

        tagged.include?([repo, version]) ? :tagged : :missing
      end
    end
  end

  let(:graph) { Ancora::Graph.from_data(FleetFixture::NETWORK, FleetFixture::DELTA) }

  def row(report, gem)
    report.rows.find { |r| r.gem == gem }
  end

  it "reports one row per gem with ahead counts from the collector delta" do
    report = described_class.new(graph).report
    expect(report.rows.size).to eq graph.nodes.size
    expect(row(report, "metanorma-document")).to have_attributes(
      ahead_by: 131, released: "0.5.1", behind: false, tagged: nil,
    )
    expect(row(report, "metanorma-cli").ahead_by).to eq 0
  end

  it "marks a gem behind when main's version is older than its release" do
    network = { "o/a" => { "name" => "a", "main_version" => "1.0.0",
                           "deps" => [] } }
    delta = { "o/a" => { "gem" => "a", "main_version" => "1.0.0",
                         "released" => "1.1.0", "ahead_by" => 0 } }
    report = described_class.new(Ancora::Graph.from_data(network, delta)).report
    expect(row(report, "a").behind).to be true
  end

  it "flags a release whose git tag is missing, using the injected oracle" do
    tags = oracle_class.new([["metanorma/metanorma-cli", "1.17.0"]])
    report = described_class.new(graph, tags: tags).report
    expect(row(report, "metanorma-cli").tagged).to eq :tagged
    expect(row(report, "metanorma-document")).to be_untagged_release
  end

  it "keeps tag status unknown when the oracle could not answer" do
    network = { "o/a" => { "name" => "a", "main_version" => "1.0.0",
                           "deps" => [] } }
    delta = { "o/a" => { "gem" => "a", "repo" => "unreachable",
                         "main_version" => "1.0.0", "released" => "1.0.0",
                         "ahead_by" => 0 } }
    report = described_class.new(Ancora::Graph.from_data(network, delta),
                                 tags: oracle_class.new([])).report
    expect(report.rows.first.tagged).to eq :unknown
    expect(report.rows.first).not_to be_untagged_release
  end

  it "leaves tag status unknown for a never-released gem" do
    tags = oracle_class.new([])
    report = described_class.new(graph, tags: tags).report
    expect(row(report, "xseed").tagged).to be_nil
  end

  it "carries the Drift findings as floor violations" do
    drift = described_class.new(graph).report.drift
    expect(drift.stale_pins.map(&:to)).to contain_exactly("glossarist",
                                                          "isodoc-i18n")
    expect(drift.floorless).not_to be_empty
  end

  it "finds floors that no release satisfies yet" do
    network = {
      "o/a" => { "name" => "a", "main_version" => "1.0.0",
                 "deps" => [{ "name" => "b", "constraints" => [">= 2.0"] }] },
      "o/b" => { "name" => "b", "main_version" => "2.0.0", "deps" => [] },
    }
    delta = { "o/b" => { "gem" => "b", "main_version" => "2.0.0",
                         "released" => "1.9.0", "ahead_by" => 4 } }
    floors = described_class.new(Ancora::Graph.from_data(network, delta))
      .report.unpublished_floors
    expect(floors.map { |f| [f.from, f.to, f.released] }).to eq([%w[a b 1.9.0]])
  end

  it "flags a constrained floor on a never-released gem" do
    network = {
      "o/a" => { "name" => "a", "main_version" => "1.0.0",
                 "deps" => [{ "name" => "b", "constraints" => [">= 1.0"] }] },
      "o/b" => { "name" => "b", "main_version" => "1.0.0", "deps" => [] },
    }
    floors = described_class.new(Ancora::Graph.from_data(network, {}))
      .report.unpublished_floors
    expect(floors.map do |f|
      [f.from, f.to, f.released]
    end).to eq([["a", "b", nil]])
  end

  it "flags a floor only a prerelease satisfies, and no satisfied floor" do
    floors = described_class.new(graph).report.unpublished_floors
    expect(floors.map do |f|
      [f.from, f.to]
    end).to include(%w[metanorma-standoc relaton-cli])
  end

  it "scopes rows and floors to a chain's inventory" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "chain.yml")
      File.write(path, FleetFixture::METANORMA_CHAIN)
      report = described_class.new(graph, chain: Ancora::Chain.load(path)).report
      expect(report.rows.map(&:gem)).not_to include("lutaml", "glossarist")
      expect(report.rows.map(&:gem)).to include("metanorma-cli")
    end
  end
end
