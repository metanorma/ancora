# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Ancora::Externals do
  let(:graph) { Ancora::Graph.from_data(FleetFixture::NETWORK, FleetFixture::DELTA) }
  let(:chain) { FleetFixture.load_chain(FleetFixture::METANORMA_CHAIN) }
  let(:oracle) { Ancora::Oracle::Rubygems.new }

  def stub_versions(gem, numbers)
    stub_request(:get, "https://rubygems.org/api/v1/versions/#{gem}.json")
      .to_return(body: JSON.generate(numbers.map { |n| { "number" => n } }))
  end

  it "reports external needs satisfied by finals as promote-safe" do
    stub_versions("sts", ["0.5.7"])
    stub_versions("glossarist", %w[2.14.1 2.13.0])
    stub_versions("ea", ["0.6.41"])
    stub_versions("relaton-cli", ["1.19.2"])
    findings = described_class.new(graph, chain: chain, oracle: oracle).check

    glossarist = findings.find { |f| f.gem == "glossarist" }
    expect(glossarist.status).to eq :satisfied
    expect(glossarist.latest_final).to eq "2.14.1"
    expect(glossarist.from).to eq(["metanorma-document"])

    ea = findings.find { |f| f.gem == "ea" }
    expect(ea.status).to eq :satisfied
  end

  it "flags needs only another chain's prerelease satisfies: awaiting release" do
    stub_versions("sts", ["0.5.7"])
    stub_versions("glossarist", %w[2.14.1 2.13.0])
    stub_versions("ea", ["0.6.41"])
    stub_versions("relaton-cli", %w[3.0.0.pre.alpha.4 1.19.2])
    findings = described_class.new(graph, chain: chain, oracle: oracle).check

    relaton = findings.find { |f| f.gem == "relaton-cli" }
    expect(relaton.status).to eq :awaiting_release
    expect(relaton.constraints).to eq(["~> 3.0"])
  end

  it "sees floors on gems without collector nodes (external chains)" do
    # sts has no node in the collected data - the edge lands in the
    # graph's external_edges, invisible to planning and drift but not
    # to the handshake check
    stub_versions("sts", ["0.5.7"])
    stub_versions("glossarist", %w[2.14.1 2.13.0])
    stub_versions("ea", ["0.6.41"])
    stub_versions("relaton-cli", ["1.19.2"])
    findings = described_class.new(graph, chain: chain, oracle: oracle).check

    sts = findings.find { |f| f.gem == "sts" }
    expect(sts.status).to eq :satisfied
    expect(sts.latest_final).to eq "0.5.7"
  end

  it "merges constraints across edges into one requirement (as bundler does)" do
    # two inventory gems pin the same external with disjoint constraints:
    # each edge alone is satisfiable, the union is not - the lock must
    # reflect the union, not the first-sorted edge
    network = FleetFixture::NETWORK.merge(
      "metanorma/metanorma-standoc" => {
        "name" => "metanorma-standoc", "main_version" => "3.5.0",
        "deps" => [
          { "name" => "metanorma-plugin-lutaml", "constraints" => ["~> 0.7.31"] },
          { "name" => "metanorma-document", "constraints" => ["~> 0.5.0"] },
          { "name" => "relaton-cli", "constraints" => ["~> 3.0"] },
          { "name" => "glossarist", "constraints" => ["~> 3.0"] },
        ]
      },
    )
    graph = Ancora::Graph.from_data(network, FleetFixture::DELTA)
    stub_versions("glossarist", %w[2.14.1 3.1.0])
    stub_versions("sts", ["0.5.7"])
    stub_versions("relaton-cli", ["3.0.0"])
    stub_versions("ea", ["0.6.41"])
    findings = described_class.new(graph, chain: chain, oracle: oracle).check

    glossarist = findings.find { |f| f.gem == "glossarist" }
    expect(glossarist.constraints).to contain_exactly("~> 2.14.1", "~> 3.0")
    expect(glossarist.from).to eq(%w[metanorma-document metanorma-standoc])
    expect(glossarist.status).to eq :awaiting_release
  end

  it "scopes needs to the chain's inventory edges only" do
    stub_request(:get, %r{rubygems\.org/api/v1/versions/})
      .to_return(body: "[]")
    findings = described_class.new(graph, chain: chain, oracle: oracle).check
    expect(findings.map(&:gem)).to contain_exactly(
      "glossarist", "relaton-cli", "ea", "sts"
    )
  end
end
