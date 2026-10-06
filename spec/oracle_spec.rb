# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Ancora::Oracle do
  let(:http) { Net::HTTP }

  before { WebMock.disable_net_connect! }

  def stub_versions(gem, body)
    stub_request(:get, "https://rubygems.org/api/v1/versions/#{gem}.json")
      .to_return(body: JSON.generate(body))
  end

  describe Ancora::Oracle::Rubygems do
    let(:oracle) { described_class.new(http: http) }
    let(:versions) do
      [{ "number" => "1.17.0" }, { "number" => "1.16.6" },
       { "number" => "1.17.1.pre.alpha.2" }]
    end

    it "reads publication truth from the versions API" do
      stub_versions("metanorma-cli", versions)
      expect(oracle.published?("metanorma-cli", "1.17.0")).to be true
      expect(oracle.published?("metanorma-cli", "1.99.0")).to be false
    end

    it "reads the latest release" do
      stub_versions("metanorma-cli", versions)
      expect(oracle.latest("metanorma-cli")).to eq "1.17.0"
    end

    it "counts existing alpha candidates per semver target" do
      stub_versions("metanorma-cli", versions)
      expect(oracle.next_candidate_index("metanorma-cli", "1.17.1")).to eq 2
      expect(oracle.next_candidate_index("metanorma-cli", "1.18.0")).to eq 0
    end

    it "answers nothing when the gem is unknown" do
      stub_request(:get, "https://rubygems.org/api/v1/versions/nope.json")
        .to_return(status: 404)
      expect(oracle.published?("nope", "1.0.0")).to be false
      expect(oracle.latest("nope")).to be_nil
    end
  end

  describe Ancora::Oracle::Github do
    let(:oracle) { described_class.new(http: http) }

    def stub_tags(repo, tags)
      stub_request(:get, "https://api.github.com/repos/#{repo}/tags?per_page=100")
        .to_return(body: JSON.generate(tags.map { |t| { "name" => t } }))
    end

    def stub_runs(repo, runs)
      url = "https://api.github.com/repos/#{repo}/actions/runs?branch=main&per_page=20"
      stub_request(:get,
                   url).to_return(body: JSON.generate(workflow_runs: runs))
    end

    it "reads tag truth for a repo" do
      stub_tags("metanorma/metanorma-cli", ["v1.17.0", "v1.16.6"])
      expect(oracle.tags("metanorma/metanorma-cli")).to eq(["v1.17.0",
                                                            "v1.16.6"])
      expect(oracle.tagged_version?("metanorma/metanorma-cli",
                                    "1.17.0")).to be true
      expect(oracle.tagged_version?("metanorma/metanorma-cli",
                                    "1.99.0")).to be false
    end

    it "reads the latest green run of the rake workflow on main" do
      stub_runs("metanorma/metanorma-cli", [
                  { "name" => "rake", "conclusion" => "success",
                    "head_sha" => "abc" },
                  { "name" => "release", "conclusion" => nil,
                    "head_sha" => "abc" },
                ])
      expect(oracle.green?("metanorma/metanorma-cli")).to be true
      run = oracle.latest_run("metanorma/metanorma-cli")
      expect(run["head_sha"]).to eq "abc"
    end

    it "is not green on a red or missing run" do
      stub_runs("metanorma/metanorma-cli",
                [{ "name" => "rake", "conclusion" => "failure" }])
      expect(oracle.green?("metanorma/metanorma-cli")).to be false

      stub_request(:get,
                   "https://api.github.com/repos/metanorma/metanorma-iso/actions/runs" \
                   "?branch=main&per_page=20").to_return(status: 404)
      expect(oracle.green?("metanorma/metanorma-iso")).to be false
    end

    it "filters runs by workflow name" do
      stub_runs("metanorma/metanorma-cli", [
                  { "name" => "automerge", "conclusion" => "success" },
                  { "name" => "rake", "conclusion" => "failure" },
                ])
      expect(oracle.green?("metanorma/metanorma-cli")).to be false
    end

    it "sends the bearer token when one is configured" do
      oracle = described_class.new(http: http, token: "t0k3n")
      stub = stub_request(:get, "https://api.github.com/repos/metanorma/metanorma-cli/tags?per_page=100")
        .with(headers: { "Authorization" => "Bearer t0k3n" })
        .to_return(body: "[]")
      oracle.tags("metanorma/metanorma-cli")
      expect(stub).to have_been_requested
    end
  end
end
