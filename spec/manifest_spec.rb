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

  describe "loading a hand-edited file" do
    def load_edited(attempts, state: "gating", cursor: 0)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "waves.json")
        data = {
          "chain" => "metanorma", "state" => state, "wave_cursor" => cursor,
          "promote_cursor" => 0, "approved" => false, "attempts" => attempts
        }
        File.write(path, JSON.generate(data))
        described_class.load(path)
      end
    end

    def attempt(pins, changed: [])
      { index: 1, pins: pins, created_at: "x", waves: [["metanorma-cli"]],
        gate_result: "red", changed: changed }
    end

    it "refuses a final pin, which has no target to renumber from" do
      expect { load_edited([attempt({ "metanorma-cli" => "1.17.0" })]) }
        .to raise_error(described_class::Invalid,
                        /attempt 1: pin 1\.17\.0 .*not a candidate version/)
    end

    it "refuses changed gems that are not among the pins" do
      pins = { "metanorma-cli" => "1.17.0.pre.alpha.1" }
      expect { load_edited([attempt(pins, changed: ["relaton-cli"])]) }
        .to raise_error(described_class::Invalid,
                        /attempt 1: changed.*pinned gems/)
    end

    it "refuses a wave cursor past the attempt's waves" do
      pins = { "metanorma-cli" => "1.17.0.pre.alpha.1" }
      expect { load_edited([attempt(pins)], state: "candidate", cursor: 3) }
        .to raise_error(described_class::Invalid, /wave cursor 3/)
    end

    it "refuses a gating state with no attempt to gate" do
      expect { load_edited([], state: "gating") }
        .to raise_error(described_class::Invalid, /no attempt/)
    end

    it "refuses a file that is not JSON" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "waves.json")
        File.write(path, "{ not json")
        expect { described_class.load(path) }
          .to raise_error(described_class::Invalid, /not JSON/)
      end
    end

    it "loads a well-formed attempt" do
      pins = { "metanorma-cli" => "1.17.0.pre.alpha.1" }
      reloaded = load_edited([attempt(pins, changed: ["metanorma-cli"])])
      expect(reloaded.current_attempt.changed).to eq ["metanorma-cli"]
    end
  end
end
