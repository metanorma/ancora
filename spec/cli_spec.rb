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

  it "prints a bad input as one line and exits 2, not a backtrace" do
    allow(Ancora::Graph).to receive(:load).and_raise(ArgumentError, "bad input")
    code = nil
    expect { code = described_class.run(["plan", "--network", "x.json"]) }
      .to output("ancora: bad input\n").to_stderr
    expect(code).to eq 2
  end

  it "refuses a non-list constraint in drift and drift-report in one line" do
    Dir.mktmpdir do |dir|
      network, delta, = write_data(dir)
      fleet = FleetFixture::NETWORK.merge(
        "metanorma/metanorma-cli" => { "name" => "metanorma-cli", "main_version" => "1.17.0",
                                       "deps" => [{ "name" => "metanorma-standoc", "constraints" => 5 }] },
      )
      File.write(network, JSON.generate(fleet))
      %w[drift drift-report].each do |command|
        code = nil
        expect { code = described_class.run([command, "--network", network, "--delta", delta]) }
          .to output(/^ancora: metanorma-cli -> metanorma-standoc: constraints must be a list/).to_stderr
        expect(code).to eq 2
      end
    end
  end

  it "names a missing network file in one line and exits 2" do
    code = nil
    expect { code = described_class.run(["plan", "--network", "/no/such/network.json"]) }
      .to output(/^ancora: \/no\/such\/network\.json: no such network file/).to_stderr
    expect(code).to eq 2
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

  it "reports a hand-edited manifest in one line and exits 2" do
    Dir.mktmpdir do |dir|
      manifest = File.join(dir, "waves.json")
      File.write(manifest, JSON.generate(
                             "chain" => "metanorma", "state" => "planned",
                             "attempts" => [{ "index" => 1, "pins" => { "metanorma-cli" => "1.17.0" },
                                              "created_at" => "x", "waves" => [], "gate_result" => nil,
                                              "changed" => [] }]
                           ))
      code = nil
      expect { code = described_class.run(["approve", "--manifest", manifest]) }
        .to output(/pin 1\.17\.0 is not a candidate version/).to_stderr
      expect(code).to eq 2
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

  it "exits non-zero and names the violated rule for a bad checkout" do
    Dir.mktmpdir do |root|
      code = nil
      expect { code = described_class.run(["policy", root]) }
        .to output(/release_workflow: missing.*lockfile_uncommitted.*2 violation/m).to_stdout
      expect(code).to eq(1)
    end
  end

  it "renders release notes from a PR file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "prs.json")
      File.write(path, JSON.generate([{ "number" => 1, "title" => "T", "mergedAt" => "2026-11-01T00:00:00Z" }]))
      expect { described_class.run(["notes", "--prs", path, "--version", "1.0.1"]) }
        .to output(/## 1.0.1\n\n- T \(#1\)/).to_stdout
    end
  end

  describe "drift-report" do
    it "prints the markdown report" do
      Dir.mktmpdir do |dir|
        network, delta, = write_data(dir)
        out = capture_stdout do
          expect(described_class.run(["drift-report", "--network", network, "--delta", delta])).to eq 0
        end
        expect(out).to include("## Summary", "`metanorma-document`", "## Stale pins (2)")
      end
    end

    it "refuses to report from a missing delta snapshot" do
      Dir.mktmpdir do |dir|
        network, = write_data(dir)
        status = nil
        expect do
          status = described_class.run(["drift-report", "--network", network,
                                        "--delta", File.join(dir, "nope.json")])
        end.to output(/no such file: .*nope.json/).to_stderr
        expect(status).to eq 1
      end
    end

    it "checks release tags only on request" do
      Dir.mktmpdir do |dir|
        network, delta, = write_data(dir)
        stub_request(:get, %r{api.github.com/repos/.+/tags}).to_return(body: "[]")
        out = capture_stdout do
          described_class.run(["drift-report", "--network", network, "--delta", delta, "--tags"])
        end
        expect(out).to match(/latest release without a git tag: [1-9]/)
      end
    end

    it "files the issue when --issue is given and a token exists" do
      Dir.mktmpdir do |dir|
        network, delta, = write_data(dir)
        stub_request(:get, %r{api.github.com/repos/o/r/issues\?}).to_return(body: "[]")
        create = stub_request(:post, "https://api.github.com/repos/o/r/issues")
          .to_return(body: JSON.generate("html_url" => "https://x/1"))
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with("GITHUB_TOKEN", nil).and_return("t")
        capture_stdout do
          expect do
            described_class.run(["drift-report", "--network", network, "--delta", delta, "--issue", "o/r"])
          end.to output(%r{issue: https://x/1}).to_stderr
        end
        expect(create).to have_been_requested
      end
    end

    it "refuses --issue without a token" do
      Dir.mktmpdir do |dir|
        network, delta, = write_data(dir)
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with("GITHUB_TOKEN", nil).and_return(nil)
        allow(ENV).to receive(:fetch).with("GH_TOKEN", nil).and_return(nil)
        status = nil
        capture_stdout do
          expect do
            status = described_class.run(["drift-report", "--network", network, "--delta", delta, "--issue", "o/r"])
          end.to output(/needs GITHUB_TOKEN/).to_stderr
        end
        expect(status).to eq 1
      end
    end
  end

  describe "plan --semantic" do
    def capture
      out = StringIO.new
      original = $stdout
      $stdout = out
      yield
      out.string
    ensure
      $stdout = original
    end

    it "plan --semantic prints fewer waves and the floorless remainder" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "n.json"), JSON.generate(FleetFixture::NETWORK))
        File.write(File.join(dir, "d.json"), JSON.generate(FleetFixture::DELTA))
        args = ["plan", "--network", File.join(dir, "n.json"), "--delta",
                File.join(dir, "d.json")]
        plain = capture { described_class.run(args.dup) }
        semantic = capture { described_class.run(args + ["--semantic"]) }
        expect(semantic).to include("floorless edges still ordering the plan")
        expect(plain).not_to include("still ordering")
        expect(semantic.scan(/^wave /).size).to be <= plain.scan(/^wave /).size
      end
    end
  end
end
