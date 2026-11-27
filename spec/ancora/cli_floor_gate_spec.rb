# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Ancora::CLI do
  let(:pins) do
    { "metanorma-iso" => "3.5.1.pre.alpha.1",
      "metanorma-cli" => "1.18.0.pre.alpha.1" }
  end
  let(:glossarist_line) { %(  spec.add_dependency "glossarist", "~> 2.14.1"\n) }
  let(:glossarist_fixed) do
    %(  spec.add_dependency "glossarist", ">= 2.14.1"\n)
  end

  def write_data(dir)
    network = File.join(dir, "network.json")
    delta = File.join(dir, "delta.json")
    chain = File.join(dir, "chain.yml")
    File.write(network, JSON.generate(FleetFixture::GATE_NETWORK))
    File.write(delta, JSON.generate(FleetFixture::DELTA))
    File.write(chain, FleetFixture::METANORMA_CHAIN)
    [network, delta, chain]
  end

  def gating_manifest(dir)
    path = File.join(dir, "waves.json")
    Ancora::Manifest.new("metanorma")
      .open_attempt(pins, [%w[metanorma-iso], %w[metanorma-cli]])
      .gate!.write(path)
    path
  end

  def recorded_result(dir)
    Ancora::Manifest.load(File.join(dir, "waves.json"))
      .current_attempt.gate_result
  end

  def recorded_changed(dir)
    Ancora::Manifest.load(File.join(dir, "waves.json"))
      .current_attempt.changed
  end

  describe "floors" do
    it "lists the fixable floors and exits 1 while fixes are pending" do
      Dir.mktmpdir do |dir|
        network, delta, = write_data(dir)
        code = nil
        expect do
          code = described_class.run(["floors", "--network", network,
                                      "--delta", delta])
        end.to output(/document -> glossarist \[stale_pin\].*>= 2.14.1/)
          .to_stdout
        expect(code).to eq 1
      end
    end

    it "patches gemspecs under --root and exits 0" do
      Dir.mktmpdir do |dir|
        network, delta, chain = write_data(dir)
        root = File.join(dir, "checkouts")
        gemspec = File.join(root, "metanorma-document",
                            "metanorma-document.gemspec")
        FileUtils.mkdir_p(File.dirname(gemspec))
        File.write(gemspec, glossarist_line)
        code = nil
        expect do
          code = described_class.run(
            ["floors", "--network", network, "--delta", delta,
             "--chain", chain, "--root", root, "--apply"],
          )
        end.to output(/metanorma-document -> glossarist: patched/).to_stdout
        expect(File.read(gemspec)).to eq glossarist_fixed
        expect(code).to eq 0
      end
    end

    it "refuses --apply without --root" do
      Dir.mktmpdir do |dir|
        network, delta, = write_data(dir)
        code = nil
        expect do
          code = described_class.run(["floors", "--network", network,
                                      "--delta", delta, "--apply"])
        end.to output(/usage/).to_stderr
        expect(code).to eq 1
      end
    end
  end

  describe "gate" do
    def run_gate(dir, shell, *extra)
      network, delta, chain = write_data(dir)
      described_class.run(
        ["gate", "--chain", chain, "--network", network, "--delta", delta,
         "--manifest", gating_manifest(dir),
         "--workdir", File.join(dir, "work"), *extra],
        shell: shell,
      )
    end

    it "exits 0 when green and records only with --record" do
      Dir.mktmpdir do |dir|
        code = nil
        expect { code = run_gate(dir, RecordingShell.new) }
          .to output(/gate attempt 1: GREEN/).to_stdout
        expect(code).to eq 0
        expect(recorded_result(dir)).to be_nil

        expect { run_gate(dir, RecordingShell.new, "--record") }
          .to output.to_stdout
        expect(recorded_result(dir)).to eq "green"
      end
    end

    it "exits 1 on red, naming the suspect gems, and records red" do
      Dir.mktmpdir do |dir|
        shell = RecordingShell.new(fail_on: ["jis bundle exec rake site"])
        code = nil
        expect { code = run_gate(dir, shell, "--record") }
          .to output(/suspects .*: metanorma-cli/).to_stdout
        expect(code).to eq 1
        expect(recorded_result(dir)).to eq "red"
        expect(recorded_changed(dir)).to eq ["metanorma-cli"]
      end
    end

    it "reopens the suspect gems as the next attempt after a red record" do
      Dir.mktmpdir do |dir|
        shell = RecordingShell.new(fail_on: ["jis bundle exec rake site"])
        expect { run_gate(dir, shell, "--record") }.to output.to_stdout
        stub_request(:get, %r{rubygems\.org/api/v1/versions/})
          .to_return(body: "[]")
        network, delta, chain = write_data(dir)
        manifest = File.join(dir, "waves.json")

        expect do
          described_class.run(["step", "--chain", chain, "--network", network,
                               "--delta", delta, "--manifest", manifest])
        end.to output(/dispatch wave 1/).to_stdout
        expect(Ancora::Manifest.load(manifest).current_attempt.index).to eq 2
      end
    end

    it "sends no git auth header for an empty GITHUB_TOKEN" do
      Dir.mktmpdir do |dir|
        shell = RecordingShell.new
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with("GITHUB_TOKEN", nil).and_return("")
        run_gate(dir, shell)

        clone = shell.calls.find { |c| c[:command].start_with?("git clone") }
        expect(clone[:env]).not_to have_key("GIT_CONFIG_COUNT")
      end
    end

    it "refuses another chain's manifest and records nothing" do
      Dir.mktmpdir do |dir|
        shell = RecordingShell.new
        network, delta, chain = write_data(dir)
        manifest = File.join(dir, "other.json")
        Ancora::Manifest.new("lutaml").open_attempt(pins, [%w[ea]])
          .gate!.write(manifest)
        code = nil
        expect do
          code = described_class.run(
            ["gate", "--chain", chain, "--network", network, "--delta", delta,
             "--manifest", manifest, "--record"], shell: shell
          )
        end.to output(/belongs to chain lutaml, not metanorma/).to_stderr
        expect(code).to eq 2
        expect(shell.calls).to be_empty
        expect(JSON.parse(File.read(manifest))["attempts"].first["gate_result"])
          .to be_nil
      end
    end

    it "does nothing unless the manifest is gating" do
      Dir.mktmpdir do |dir|
        network, delta, chain = write_data(dir)
        shell = RecordingShell.new
        code = nil
        expect do
          code = described_class.run(
            ["gate", "--chain", chain, "--network", network, "--delta", delta,
             "--manifest", File.join(dir, "missing.json")], shell: shell
          )
        end.to output(/not in the gating state/).to_stderr
        expect(code).to eq 2
        expect(shell.calls).to be_empty
      end
    end
  end
end
