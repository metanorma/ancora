# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"
require "webmock/rspec"

RSpec.describe Ancora::CLI do
  # writes the fixture as collector-style files the CLI can load
  def write_data(dir)
    File.write(File.join(dir, "network.json"), JSON.pretty_generate(FleetFixture::NETWORK))
    File.write(File.join(dir, "delta.json"), JSON.pretty_generate(FleetFixture::DELTA))
    chain = File.join(dir, "chain.yml")
    File.write(chain, FleetFixture::METANORMA_CHAIN)
    [File.join(dir, "network.json"), File.join(dir, "delta.json"), chain]
  end

  def stub_versions(gem, numbers)
    stub_request(:get, "https://rubygems.org/api/v1/versions/#{gem}.json")
      .to_return(body: JSON.generate(numbers.map { |n| { "number" => n } }))
  end

  def capture_stdout
    captured = StringIO.new
    original = $stdout
    $stdout = captured
    yield
    captured.string
  ensure
    $stdout = original
  end

  it "plans waves over collector data and exits zero" do
    Dir.mktmpdir do |dir|
      network, delta, = write_data(dir)
      code = nil
      expect do
        code = described_class.run(["plan", "--network", network, "--delta",
                                    delta])
      end.to output(/scope: full.*wave 1:/m).to_stdout
      expect(code).to eq 0
    end
  end

  it "prints the whole-chain pin set" do
    Dir.mktmpdir do |dir|
      network, delta, chain = write_data(dir)
      code = nil
      expect do
        code = described_class.run(
          ["pin", "--chain", chain, "--network", network, "--delta", delta],
        )
      end.to output(%r{gem "metanorma-cli", "1.17.0"}).to_stdout
      expect(code).to eq 0
    end
  end

  it "reports drift for the whole fleet" do
    Dir.mktmpdir do |dir|
      network, delta, = write_data(dir)
      code = nil
      expect do
        code = described_class.run(["drift", "--network", network, "--delta",
                                    delta])
      end.to output(/floorless edges \(4\).*stale pins \(2\)/m).to_stdout
      expect(code).to eq 0
    end
  end

  it "performs one step and commits the manifest" do
    Dir.mktmpdir do |dir|
      network, delta, chain = write_data(dir)
      manifest = File.join(dir, "state", "waves.json")
      stub_request(:get, %r{rubygems\.org/api/v1/versions/})
        .to_return(body: "[]")
      code = nil
      expect do
        code = described_class.run(
          ["step", "--chain", chain, "--network", network, "--delta", delta,
           "--manifest", manifest],
        )
      end.to output(/state: candidate.*dispatch wave 1/m).to_stdout
      expect(code).to eq 0
      expect(JSON.parse(File.read(manifest))["state"]).to eq "candidate"
    end
  end

  it "emits the action as JSON for the runtime workflow" do
    Dir.mktmpdir do |dir|
      network, delta, chain = write_data(dir)
      stub_request(:get, %r{rubygems\.org/api/v1/versions/})
        .to_return(body: "[]")
      out = capture_stdout do
        described_class.run(
          ["step", "--chain", chain, "--network", network, "--delta", delta,
           "--format", "json"],
        )
      end
      payload = JSON.parse(out)
      expect(payload["action"]).to eq "dispatch_wave"
      expect(payload["state"]).to eq "candidate"
      expect(payload["items"].first).to eq(
        "gem" => "metanorma-document",
        "repo" => "metanorma/metanorma-document",
        "version" => "0.5.2.pre.alpha.1",
      )
    end
  end

  it "approves a wave through the manifest" do
    Dir.mktmpdir do |dir|
      manifest = File.join(dir, "waves.json")
      Ancora::Manifest.new("metanorma")
        .open_attempt({ "ea" => "0.6.42.pre.alpha.1" }).write(manifest)
      code = nil
      expect do
        code = described_class.run(["approve", "--manifest", manifest])
      end.to output(/approved for promotion/).to_stdout
      expect(code).to eq 0
      expect(Ancora::Manifest.load(manifest)).to be_approved
    end
  end

  it "checks publication truth against the oracle" do
    stub_versions("metanorma-cli", ["1.17.0"])
    code = nil
    expect do
      code = described_class.run(["check", "metanorma-cli", "1.17.0"])
    end.to output(/metanorma-cli 1\.17\.0: published/).to_stdout
    expect(code).to eq 0
  end

  it "blocks the complete gate lock on awaiting-release externals" do
    Dir.mktmpdir do |dir|
      network, delta, chain = write_data(dir)
      # relaton-cli satisfies only by prerelease; the rest have finals
      stub_versions("glossarist", %w[2.14.1 2.13.0])
      stub_versions("ea", ["0.6.41"])
      stub_versions("sts", ["0.5.7"])
      stub_versions("relaton-cli", %w[3.0.0.pre.alpha.4 1.19.2])
      code = nil
      expect do
        code = described_class.run(
          ["pin", "--chain", chain, "--network", network, "--delta", delta,
           "--externals"],
        )
      end.to output(/# external chains - finals.*gem "ea", "0\.6\.41"/m).to_stdout
      expect(code).to eq 1
    end
  end

  it "externals exits 1 while a chain cannot promote (gate semantics)" do
    Dir.mktmpdir do |dir|
      network, delta, chain = write_data(dir)
      stub_versions("glossarist", %w[2.14.1 2.13.0])
      stub_versions("ea", ["0.6.41"])
      stub_versions("sts", ["0.5.7"])
      stub_versions("relaton-cli", %w[3.0.0.pre.alpha.4 1.19.2])
      code = nil
      expect do
        code = described_class.run(
          ["externals", "--chain", chain, "--network", network, "--delta",
           delta],
        )
      end.to output(/awaiting release.*\(1\).*relaton-cli/m).to_stdout
      expect(code).to eq 1
    end
  end

  it "prints usage and exits 1 for an unknown command" do
    code = nil
    expect { code = described_class.run(["bogus"]) }
      .to output(/usage: ancora plan/).to_stderr
    expect(code).to eq 1
  end
end
