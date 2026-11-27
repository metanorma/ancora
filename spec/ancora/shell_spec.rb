# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ancora::Shell do
  it "captures output and status of a real subprocess" do
    ok = described_class.new.run(%w[ruby -e puts(1)], chdir: Dir.pwd)
    bad = described_class.new.run("echo nope; exit 3", chdir: Dir.pwd)

    expect([ok.ok?, ok.output]).to eq [true, "1\n"]
    expect([bad.ok?, bad.output]).to eq [false, "nope\n"]
  end

  it "kills a command that overruns its timeout" do
    result = described_class.new.run("sleep 30", chdir: Dir.pwd, timeout: 0.2)

    expect(result).to have_attributes(ok?: false, timed_out: true)
  end

  it "reports a missing executable as a failure, not an exception" do
    result = described_class.new.run(%w[ancora-no-such-binary], chdir: Dir.pwd)

    expect(result.ok?).to be false
  end
end
