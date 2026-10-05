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
end
