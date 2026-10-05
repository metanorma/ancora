# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Ancora::Machine do
  let(:graph) { Ancora::Graph.from_data(FleetFixture::NETWORK, FleetFixture::DELTA) }
  let(:chain) { FleetFixture.load_chain(chain_yaml) }
  let(:chain_yaml) { FleetFixture::METANORMA_CHAIN }
  let(:manifest) { Ancora::Manifest.new(chain.name) }
  let(:targets) do
    { "metanorma-document" => "0.5.2", "metanorma-standoc" => "3.5.1" }
  end

  # one step = one runtime run = one fresh process = a fresh oracle
  # snapshot; the manifest is the only state that crosses steps
  def machine
    described_class.new(chain: chain, graph: graph,
                        oracle: Ancora::Oracle::Rubygems.new)
  end

  def stub_versions(gem, numbers)
    stub_request(:get, "https://rubygems.org/api/v1/versions/#{gem}.json")
      .to_return(body: JSON.generate(numbers.map { |n| { "number" => n } }))
  end

  # versions the oracle reports published; re-stubbed on every publish
  # so newer stubs shadow the catch-all
  def stub_all_versions
    stub_request(:get, %r{rubygems\.org/api/v1/versions/})
      .to_return(body: "[]")
    published.each { |gem, numbers| stub_versions(gem, numbers) }
  end

  def publish(gem, numbers)
    published[gem].concat(numbers)
    stub_all_versions
  end

  def published
    @published ||= Hash.new { |h, k| h[k] = [] }
  end

  it "opens the first attempt with oracle-numbered candidates and dispatches wave 1" do
    stub_all_versions
    action = machine.step(manifest, targets)
    expect(action).to be_a(described_class::DispatchWave)
    expect(action.index).to eq 0
    expect(action.items.map { |i| [i.gem, i.version] }).to eq(
      [["metanorma-document", "0.5.2.pre.alpha.1"]],
    )
    expect(manifest.state).to eq "candidate"
    expect(manifest.current_attempt.pins).to eq(
      "metanorma-document" => "0.5.2.pre.alpha.1",
      "metanorma-standoc" => "3.5.1.pre.alpha.1",
    )
    expect(manifest.current_attempt.waves).to eq(
      [["metanorma-document"], ["metanorma-standoc"]],
    )
  end

  it "takes candidate targets from the graph's main versions when not supplied" do
    stub_all_versions
    machine.step(manifest)
    expect(manifest.current_attempt.pins).to include(
      "metanorma-document" => "0.5.2.pre.alpha.1",
    )
  end

  it "raises when a planned gem has no owner-decided target version" do
    bare = Ancora::Graph.from_data(
      { "r/g" => { "name" => "g", "main_version" => nil, "deps" => [] } },
      { "r/g" => { "gem" => "g", "ahead_by" => 1 } },
    )
    m = described_class.new(
      chain: FleetFixture.load_chain("name: solo\ninventory:\n  gems: [g]\n"),
      graph: bare, oracle: Ancora::Oracle::Rubygems.new
    )
    expect { m.step(manifest) }
      .to raise_error(described_class::Error, /target version for g/)
  end

  it "re-dispatches an unpublished candidate wave (resume is idempotent)" do
    stub_all_versions
    machine.step(manifest, targets)
    action = machine.step(manifest)
    expect(action).to be_a(described_class::DispatchWave)
    expect(action.index).to eq 0
  end

  it "advances to the next wave when the current one is fully published" do
    stub_all_versions
    machine.step(manifest, targets)
    publish("metanorma-document", ["0.5.2.pre.alpha.1"])
    action = machine.step(manifest)
    expect(action.index).to eq 1
    expect(action.items.map(&:gem)).to eq(["metanorma-standoc"])
  end

  it "gates once every candidate of every wave is visible" do
    stub_all_versions
    machine.step(manifest, targets)
    publish("metanorma-document", ["0.5.2.pre.alpha.1"])
    publish("metanorma-standoc", ["3.5.1.pre.alpha.1"])
    machine.step(manifest) # advance past wave 1
    action = machine.step(manifest) # gate
    expect(action).to be_a(described_class::Gate)
    expect(manifest.state).to eq "gating"
  end

  it "re-attempts only the changed gems after a red gate" do
    stub_all_versions
    machine.step(manifest, targets)
    publish("metanorma-document", ["0.5.2.pre.alpha.1"])
    publish("metanorma-standoc", ["3.5.1.pre.alpha.1"])
    machine.step(manifest)
    machine.step(manifest)
    manifest.record_gate!("red", ["metanorma-document"])

    action = machine.step(manifest, "metanorma-document" => "0.5.2")
    expect(action).to be_a(described_class::DispatchWave)
    expect(manifest.state).to eq "candidate"
    expect(manifest.current_attempt.index).to eq 2
    expect(manifest.current_attempt.pins).to eq(
      "metanorma-document" => "0.5.2.pre.alpha.2",
      "metanorma-standoc" => "3.5.1.pre.alpha.1",
    )
  end

  it "halts for humans at max_attempts" do
    stub_all_versions
    machine.step(manifest, targets)
    2.times do
      publish("metanorma-document", ["0.5.2.pre.alpha.1"])
      publish("metanorma-standoc", ["3.5.1.pre.alpha.1"])
      machine.step(manifest)
      machine.step(manifest)
      manifest.record_gate!("red")
      machine.step(manifest)
    end
    publish("metanorma-document", ["0.5.2.pre.alpha.1"])
    publish("metanorma-standoc", ["3.5.1.pre.alpha.1"])
    machine.step(manifest)
    machine.step(manifest)
    manifest.record_gate!("red")
    action = machine.step(manifest)
    expect(action).to be_a(described_class::Halt)
    expect(action.reason).to include("3 attempts")
  end

  it "promotes from the first green attempt in wave order, finals only" do
    stub_all_versions
    machine.step(manifest, targets)
    publish("metanorma-document", ["0.5.2.pre.alpha.1"])
    publish("metanorma-standoc", ["3.5.1.pre.alpha.1"])
    machine.step(manifest)
    machine.step(manifest)
    manifest.record_gate!("red", ["metanorma-document"])
    machine.step(manifest, "metanorma-document" => "0.5.2")
    publish("metanorma-document", ["0.5.2.pre.alpha.2"])
    machine.step(manifest)
    machine.step(manifest)
    manifest.record_gate!("green")

    action = machine.step(manifest)
    expect(action).to be_a(described_class::PromoteWave)
    expect(action.index).to eq 0
    expect(action.items.map { |i| [i.gem, i.version] }).to eq(
      [["metanorma-document", "0.5.2"]],
    )
    expect(manifest.state).to eq "promoted"
  end

  it "finishes when the last wave's finals are visible" do
    stub_all_versions
    machine.step(manifest, targets)
    publish("metanorma-document", ["0.5.2.pre.alpha.1", "0.5.2"])
    publish("metanorma-standoc", ["3.5.1.pre.alpha.1", "3.5.1"])
    machine.step(manifest)
    machine.step(manifest)
    manifest.record_gate!("green")
    action = machine.step(manifest)
    expect(action).to be_a(described_class::PromoteWave)
    expect(action.index).to eq 0

    action = machine.step(manifest)
    expect(action).to be_a(described_class::PromoteWave)
    expect(action.index).to eq 1

    action = machine.step(manifest)
    expect(action).to be_a(described_class::Done)
    expect(manifest.state).to eq "done"
  end

  it "re-promotes a wave whose finals are not visible yet (idempotent)" do
    stub_all_versions
    machine.step(manifest, targets)
    publish("metanorma-document", ["0.5.2.pre.alpha.1", "0.5.2"])
    publish("metanorma-standoc", ["3.5.1.pre.alpha.1"])
    machine.step(manifest)
    machine.step(manifest)
    manifest.record_gate!("green")
    machine.step(manifest) # promote wave 1 finals
    machine.step(manifest) # wave 1 finals visible, advance to wave 2

    action = machine.step(manifest) # wave 2 finals not visible: re-promote
    expect(action).to be_a(described_class::PromoteWave)
    expect(action.index).to eq 1
    expect(manifest.state).to eq "promoted"
  end

  it "runs the glossarist single-gem chain through its whole lifecycle" do
    chain = FleetFixture.load_chain(FleetFixture::GLOSSARIST_CHAIN)
    m = described_class.new(chain: chain, graph: graph,
                            oracle: Ancora::Oracle::Rubygems.new)
    stub_all_versions
    action = m.step(manifest)
    expect(action.items.map { |i| [i.gem, i.version] })
      .to eq([["glossarist", "2.15.0.pre.alpha.1"]])
    publish("glossarist", ["2.15.0.pre.alpha.1"])
    m = described_class.new(chain: chain, graph: graph,
                            oracle: Ancora::Oracle::Rubygems.new)
    expect(m.step(manifest)).to be_a(described_class::Gate)
    manifest.record_gate!("green")
    publish("glossarist", ["2.15.0"])
    m = described_class.new(chain: chain, graph: graph,
                            oracle: Ancora::Oracle::Rubygems.new)
    expect(m.step(manifest)).to be_a(described_class::PromoteWave)
    m = described_class.new(chain: chain, graph: graph,
                            oracle: Ancora::Oracle::Rubygems.new)
    expect(m.step(manifest)).to be_a(described_class::Done)
  end
end
