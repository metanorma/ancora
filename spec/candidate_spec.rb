# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ancora::Candidate do
  it "builds candidate versions with one-based counters" do
    expect(described_class.version("3.6.0", 0)).to eq "3.6.0.pre.alpha.1"
    expect(described_class.version("3.6.0", 4)).to eq "3.6.0.pre.alpha.5"
  end

  it "recovers the semver target and recognizes candidates" do
    expect(described_class.target_of("1.2.3.pre.alpha.7")).to eq "1.2.3"
    expect(described_class.candidate?("1.2.3.pre.alpha.7")).to be true
    expect(described_class.candidate?("1.2.3")).to be false
  end

  it "separates counters across semver targets" do
    expect(described_class.target_of("3.7.0.pre.alpha.1"))
      .not_to eq(described_class.target_of("3.6.0.pre.alpha.9"))
  end
end
