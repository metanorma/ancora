# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ancora::FloorFixer do
  def node(name, main, _released, repo: "org/#{name}")
    { repo => { "name" => name, "main_version" => main,
                "deps" => yield } }
  end

  def graph(nodes, released)
    network = nodes.reduce({}) { |acc, n| acc.merge(n) }
    delta = released.to_h do |gem, version|
      [gem, { "gem" => gem, "main_version" => version, "released" => version,
              "ahead_by" => 0 }]
    end
    Ancora::Graph.from_data(network, delta)
  end

  subject(:plan) { described_class.new(fleet).plan }

  let(:fleet) do
    graph(
      [node("app", "1.0.0", nil) do
        [{ "name" => "floorless", "constraints" => [] },
         { "name" => "prerel", "constraints" => ["~> 2.0.0.pre.alpha"] },
         { "name" => "stale", "constraints" => ["~> 1.2.0"] },
         { "name" => "fine", "constraints" => ["~> 1.0"] },
         { "name" => "unreleased", "constraints" => [] },
         { "name" => "alpha-only", "constraints" => ["~> 3.0.0.pre.alpha"] }]
      end,
       node("floorless", "1.4.0", nil) { [] },
       node("prerel", "2.0.1", nil) { [] },
       node("stale", "1.3.0", nil) { [] },
       node("fine", "1.0.5", nil) { [] },
       node("unreleased", "0.1.0", nil) { [] },
       node("alpha-only", "3.0.0.pre.alpha.2", nil) { [] }],
      { "app" => "1.0.0", "floorless" => "1.4.0", "prerel" => "2.0.1",
        "stale" => "1.3.0", "fine" => "1.0.5",
        "alpha-only" => "3.0.0.pre.alpha.2" },
    )
  end

  it "skips an unreadable edge and still plans the others" do
    fleet = graph(
      [node("app", "1.0.0", nil) do
        [{ "name" => "broken", "constraints" => ["not a requirement"] },
         { "name" => "stale", "constraints" => ["~> 1.2.0"] }]
      end,
       node("broken", "1.0.0", nil) { [] },
       node("stale", "1.3.0", nil) { [] }],
      { "app" => "1.0.0", "broken" => "1.0.0", "stale" => "1.3.0" },
    )
    plan = described_class.new(fleet).plan

    expect(plan.fixes.map(&:to)).to eq ["stale"]
    expect(plan.skipped.map do |s|
      [s.to, s.kind]
    end).to eq [["broken", :unreadable]]
    expect(plan.skipped.first.reason).to include("constraints cannot be read")
  end

  it "keeps the clauses a stale pin does not replace" do
    fleet = graph(
      [node("app", "1.0.0", nil) do
        [{ "name" => "stale", "constraints" => ["~> 1.2.0", "< 2"] }]
      end,
       node("stale", "1.3.0", nil) { [] }],
      { "app" => "1.0.0", "stale" => "1.3.0" },
    )
    fixes = described_class.new(fleet).plan.fixes
    expect(fixes.map(&:proposed)).to eq [["< 2", ">= 1.3.0"]]
  end

  it "raises each broken floor to the released final" do
    proposals = plan.fixes.to_h { |f| [f.to, [f.kind, f.proposed]] }

    expect(proposals).to eq(
      "floorless" => [:floorless, [">= 1.4.0"]],
      "prerel" => [:prerelease_floor, [">= 2.0.1"]],
      "stale" => [:stale_pin, [">= 1.3.0"]],
    )
  end

  it "leaves a sound floor untouched" do
    expect((plan.fixes + plan.skipped).map(&:to)).not_to include("fine")
  end

  it "skips, with the reason, a dependency that has no released final" do
    skipped = plan.skipped.to_h { |s| [s.to, s.reason] }

    expect(skipped["unreleased"]).to eq "unreleased has no released final"
    expect(skipped["alpha-only"]).to eq "alpha-only has no released final"
  end

  it "keeps the non-prerelease clauses when replacing a prerelease clause" do
    graph = graph(
      [node("app", "1.0.0", nil) do
        [{ "name" => "dep", "constraints" => [">= 1.0.0.pre.alpha", "< 3"] }]
      end,
       node("dep", "2.0.0", nil) { [] }],
      { "dep" => "2.0.0" },
    )

    fix = described_class.new(graph).plan.fixes.first

    expect(fix.proposed).to eq(["< 3", ">= 2.0.0"])
  end

  it "refuses a final older than the prerelease floor it would replace" do
    graph = graph(
      [node("app", "1.0.0", nil) do
        [{ "name" => "dep", "constraints" => ["~> 2.0.0.pre.alpha"] }]
      end,
       node("dep", "2.0.0.pre.alpha.5", nil) { [] }],
      { "dep" => "1.9.0" },
    )

    plan = described_class.new(graph).plan

    expect(plan.fixes).to be_empty
    expect(plan.skipped.first.reason)
      .to include("older than the prerelease floor")
  end

  it "scopes to the chain inventory" do
    chain = FleetFixture.load_chain(FleetFixture::GLOSSARIST_CHAIN)
    fleet = Ancora::Graph.from_data(FleetFixture::NETWORK, FleetFixture::DELTA)

    expect(described_class.new(fleet, chain: chain).plan.fixes).to be_empty
    expect(described_class.new(fleet).plan.fixes.map(&:to))
      .to include("glossarist")
  end

  it "finds the stale glossarist pin in the real fleet slice" do
    fleet = Ancora::Graph.from_data(FleetFixture::NETWORK, FleetFixture::DELTA)

    fix = described_class.new(fleet).plan.fixes
      .find { |f| f.to == "glossarist" }

    expect([fix.from, fix.kind, fix.proposed])
      .to eq ["metanorma-document", :stale_pin, [">= 2.14.1"]]
  end

  it "skips a prerelease fix whose proposal would admit nothing" do
    graph = graph(
      [node("app", "1.0.0", nil) do
        [{ "name" => "dep",
           "constraints" => [">= 2.0.0.pre.alpha", "< 2.0.0"] }]
      end,
       node("dep", "2.0.0", nil) { [] }],
      { "dep" => "2.0.0" },
    )

    plan = described_class.new(graph).plan

    expect(plan.fixes).to be_empty
    expect(plan.skipped.first.reason).to include("excludes released 2.0.0")
  end

  it "never lowers a floor the owner set above the released version" do
    graph = graph(
      [node("app", "1.0.0", nil) do
        [{ "name" => "dep", "constraints" => [">= 2.0.0"] }]
      end,
       node("dep", "1.9.0", nil) { [] }],
      { "dep" => "1.5.0" },
    )

    plan = described_class.new(graph).plan

    expect(plan.fixes).to be_empty
    expect(plan.skipped.first.reason)
      .to eq "floor 2.0.0 is above released 1.5.0"
  end

  it "keeps a strict floor from being relaxed to an inclusive one" do
    graph = graph(
      [node("app", "1.0.0", nil) do
        [{ "name" => "dep", "constraints" => ["> 2.0.0"] }]
      end,
       node("dep", "2.1.0", nil) { [] }],
      { "dep" => "2.0.0" },
    )

    plan = described_class.new(graph).plan

    expect(plan.fixes).to be_empty
    expect(plan.skipped.first.reason).to include("is above released 2.0.0")
  end
end
