# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Ancora::IssueSink do
  let(:sink) { described_class.new("metanorma/ancora", token: "tkn") }
  let(:issues) { "https://api.github.com/repos/metanorma/ancora/issues" }
  let(:list) { "#{issues}?state=open&per_page=100&labels=drift-report" }

  def publish
    sink.publish(title: "Fleet drift report 2026-W48", body: "B",
                 label: "drift-report")
  end

  it "creates the issue when none is open with that title" do
    stub_request(:get,
                 list).to_return(body: JSON.generate([{ "number" => 1,
                                                        "title" => "other" }]))
    create = stub_request(:post, issues)
      .with(headers: { "Authorization" => "Bearer tkn" },
            body: { title: "Fleet drift report 2026-W48", body: "B",
                    labels: ["drift-report"] })
      .to_return(body: JSON.generate("html_url" => "https://x/issues/9"))
    expect(publish).to eq "https://x/issues/9"
    expect(create).to have_been_requested
  end

  it "updates the open issue of the same week instead of duplicating it" do
    stub_request(:get, list).to_return(
      body: JSON.generate([{ "number" => 7,
                             "title" => "Fleet drift report 2026-W48" }]),
    )
    patch = stub_request(:patch, "#{issues}/7").with(body: { body: "B" })
      .to_return(body: JSON.generate("html_url" => "https://x/issues/7"))
    expect(publish).to eq "https://x/issues/7"
    expect(patch).to have_been_requested
    expect(a_request(:post, issues)).not_to have_been_made
  end

  it "raises with the status when GitHub refuses" do
    stub_request(:get, list).to_return(status: 403, body: "nope")
    expect { publish }.to raise_error(/403 nope/)
  end

  it "rejects a repo that is not OWNER/NAME" do
    ["o/r?state=closed#x", "o/../../user", "o", "o/r/extra"].each do |repo|
      expect { described_class.new(repo, token: "tkn") }
        .to raise_error(ArgumentError, %r{OWNER/NAME})
    end
  end
end
