# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe Ancora::Manifest do
  it "round-trips attempts through disk, a cache over the oracles" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state", "waves.json")
      described_class.new("metanorma").open_attempt(
        { "ea" => "0.6.42.pre.alpha.1" },
      ).gate!.write(path)
      reloaded = described_class.load(path)
      expect(reloaded.chain).to eq "metanorma"
      expect(reloaded.state).to eq "gating"
      expect(reloaded.current_attempt.pins)
        .to eq({ "ea" => "0.6.42.pre.alpha.1" })
    end
  end

  it "refuses to gate without an open attempt" do
    expect { described_class.new("metanorma").gate! }
      .to raise_error("no open attempt")
  end

  it "round-trips waves, gate verdicts, and cursors through disk" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state", "waves.json")
      m = described_class.new("metanorma")
      m.open_attempt({ "ea" => "0.6.42.pre.alpha.1" },
                     [["ea"], ["metanorma-standoc"]])
      m.advance_wave
      m.gate!
      m.record_gate!("red", ["ea"])
      m.write(path)

      reloaded = described_class.load(path)
      expect(reloaded.wave_cursor).to eq 1
      expect(reloaded.current_attempt.waves)
        .to eq([["ea"], ["metanorma-standoc"]])
      expect(reloaded.current_attempt.gate_result).to eq "red"
      expect(reloaded.current_attempt.changed).to eq(["ea"])
    end
  end

  it "round-trips promote approval through disk" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "waves.json")
      m = described_class.new("metanorma")
      m.open_attempt({ "ea" => "0.6.42.pre.alpha.1" })
      m.record_gate!("green")
      expect(described_class.load(path).approved?).to be false
      m.approve!
      m.write(path)
      expect(described_class.load(path).approved?).to be true
    end
  end

  it "starts promotion only from a green attempt" do
    m = described_class.new("metanorma")
    m.open_attempt({ "ea" => "0.6.42.pre.alpha.1" })
    expect { m.start_promotion(m.current_attempt) }
      .to raise_error(/not green/)
    m.record_gate!("green")
    m.start_promotion(m.current_attempt)
    expect(m.state).to eq "promoted"
    expect(m.promoted_from.index).to eq 1
  end
end
