# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ancora::DriftReport do
  let(:graph) { Ancora::Graph.from_data(FleetFixture::NETWORK, FleetFixture::DELTA) }
  let(:tags) do
    Class.new { def tag_status(_repo, _version) = :missing }.new
  end
  let(:report) { Ancora::FleetDrift.new(graph, tags: tags).report }
  let(:doc) { described_class.new(report, date: Date.new(2026, 11, 23)) }

  it "titles the issue by ISO week so reruns update one issue" do
    expect(doc.title).to eq "Fleet drift report 2026-W48"
  end

  it "gives a chain-scoped report its own issue title" do
    chain = described_class.new(report, scope: "chain metanorma",
                                        date: Date.new(2026, 11, 23))
    expect(chain.title).to eq "Fleet drift report 2026-W48 (chain metanorma)"
  end

  it "summarises counts per drift class" do
    expect(doc.body).to include("gems ahead of their release: 7")
    expect(doc.body).to include("gems behind their release: 0")
    expect(doc.body).to match(/latest release without a git tag: \d+/)
  end

  it "lists the most-ahead gem first" do
    section = doc.body[/## Ahead of release.*?(?=\n\n##)/m]
    expect(section.lines[2]).to include("`metanorma-document`",
                                        "131 commits since 0.5.1")
  end

  it "lists floor violations" do
    expect(doc.body).to include("## Stale pins (2)")
    expect(doc.body).to include("`isodoc` -> `isodoc-i18n`")
    expect(doc.body).to include("## Prerelease floors (1)")
  end

  it "says the tag check was skipped when no oracle was given" do
    plain = described_class.new(Ancora::FleetDrift.new(graph).report,
                                date: Date.new(2026, 11, 23))
    expect(plain.body).to include("without a git tag: not checked")
  end

  it "reports tag lookups GitHub did not answer as unknown, not missing" do
    silent = Class.new { def tag_status(_repo, _version) = :unknown }.new
    unknown = Ancora::FleetDrift.new(graph, tags: silent).report
    plain = described_class.new(unknown, date: Date.new(2026, 11, 23))
    expect(plain.body).to match(/without a git tag: 0 \(\d+ unknown/)
  end

  it "keeps the body under GitHub's limit" do
    stub_const("#{described_class}::MAX_BODY", 200)
    expect(doc.body).to include("(truncated;")
    expect(doc.body.size).to be < 400
  end
end
