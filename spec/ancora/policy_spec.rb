# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"

RSpec.describe Ancora::Policy do
  let(:release_yml) do
    <<~YML
      on:
        workflow_dispatch:
          inputs:
            next_version:
              required: true
        repository_dispatch:
          types: [ do-release ]
      jobs:
        release:
          uses: metanorma/ci/.github/workflows/rubygems-release.yml@main
    YML
  end

  def write(root, path, text)
    full = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  # a conforming gem checkout; the block may break one rule
  def checkout
    Dir.mktmpdir do |root|
      Open3.capture2e("git", "init", "-q", chdir: root)
      write(root, "lib/foo/version.rb", "VERSION = \"1.2.3\"\n")
      write(root, ".github/workflows/release.yml", release_yml)
      write(root, ".gitignore", "/Gemfile.lock\ncoverage/\n")
      yield root
    end
  end

  def rules(root, **opts)
    described_class.new(root, **opts).check.map(&:rule)
  end

  it "passes a conforming checkout" do
    checkout { |root| expect(rules(root, next_version: "1.2.4")).to eq([]) }
  end

  it "flags a version.rb already at or ahead of next_version" do
    checkout do |root|
      expect(rules(root, next_version: "1.2.3")).to eq([:version_behind_next])
      expect(rules(root, next_version: "1.2.0")).to eq([:version_behind_next])
    end
  end

  it "compares versions numerically, not as strings" do
    checkout { |root| expect(rules(root, next_version: "1.10.0")).to eq([]) }
  end

  it "skips the version rule without a next_version" do
    checkout do |root|
      write(root, "lib/foo/version.rb", "VERSION = \"9.9.9\"\n")
      expect(rules(root)).to eq([])
    end
  end

  it "flags a missing release workflow" do
    checkout do |root|
      File.delete(File.join(root, ".github/workflows/release.yml"))
      expect(rules(root)).to eq([:release_workflow])
    end
  end

  it "flags a release workflow that is not the reusable one" do
    checkout do |root|
      write(root, ".github/workflows/release.yml", "on: push\njobs: {}\n")
      messages = described_class.new(root).check.map(&:message)
      expect(messages.size).to eq(3)
    end
  end

  it "flags a Gemfile.lock that is not ignored" do
    checkout do |root|
      write(root, ".gitignore", "coverage/\n")
      expect(rules(root)).to eq([:lockfile_uncommitted])
    end
  end

  it "flags a Gemfile.lock tracked by git" do
    checkout do |root|
      write(root, "Gemfile.lock", "GEM\n")
      Open3.capture2e("git", "add", "-f", "Gemfile.lock", chdir: root)
      expect(described_class.new(root).check.map(&:message))
        .to include("Gemfile.lock is tracked by git")
    end
  end

  it "ignores a commented-out VERSION before the real one" do
    checkout do |root|
      write(root, "lib/foo/version.rb",
            "# VERSION = \"9.9.9\"\nmodule Foo\n  VERSION = \"1.2.3\"\nend\n")
      expect(rules(root, next_version: "1.2.4")).to eq([])
      expect(rules(root, next_version: "1.2.3")).to eq([:version_behind_next])
    end
  end

  it "flags a version.rb whose only VERSION is commented out" do
    checkout do |root|
      write(root, "lib/foo/version.rb", "# VERSION = \"0.0.1\"\n")
      policy = described_class.new(root, next_version: "1.2.4")
      expect(policy.check.map(&:message))
        .to include(a_string_matching(/no VERSION literal/))
    end
  end

  it "rejects a release workflow whose keys are only commented out" do
    checkout do |root|
      write(root, ".github/workflows/release.yml", <<~YML)
        on: push
        # workflow_dispatch:
        #   inputs:
        #     next_version:
        # types: [ do-release ]
        # uses: metanorma/ci/.github/workflows/rubygems-release.yml@main
        jobs: {}
      YML
      expect(described_class.new(root).check.map(&:message).size).to eq(3)
    end
  end

  it "rejects a release workflow whose keys are misplaced" do
    checkout do |root|
      write(root, ".github/workflows/release.yml", <<~YML)
        on:
          workflow_dispatch: {}
        env:
          next_version: x
          note: do-release
          ref: metanorma/ci/.github/workflows/rubygems-release.yml@main
        jobs:
          release:
            runs-on: ubuntu-latest
            steps:
              - run: echo uses metanorma/ci/.github/workflows/rubygems-release.yml@main
      YML
      expect(described_class.new(root).check.map(&:message).size).to eq(3)
    end
  end

  it "flags an unparseable release workflow" do
    checkout do |root|
      write(root, ".github/workflows/release.yml", "on: [unclosed\n")
      expect(rules(root)).to eq([:release_workflow])
    end
  end

  it "treats a negated Gemfile.lock ignore as not ignored" do
    checkout do |root|
      write(root, ".gitignore", "/Gemfile.lock\n!Gemfile.lock\n")
      expect(rules(root)).to eq([:lockfile_uncommitted])
    end
  end

  it "does not borrow a parent repository's ignore rule for a nested gem" do
    Dir.mktmpdir do |parent|
      Open3.capture2e("git", "init", "-q", chdir: parent)
      write(parent, ".gitignore", "Gemfile.lock\n")
      gem = File.join(parent, "gem")
      write(gem, "lib/foo/version.rb", "VERSION = \"1.2.3\"\n")
      write(gem, ".github/workflows/release.yml", release_yml)
      write(gem, "Gemfile.lock", "GEM\n")
      expect(rules(gem, next_version: "1.2.4")).to eq([:lockfile_uncommitted])
    end
  end

  it "accepts a wildcard ignore that covers Gemfile.lock" do
    checkout do |root|
      write(root, ".gitignore", "*.lock\n")
      expect(rules(root)).to eq([])
    end
  end

  it "ignores a VERSION inside a =begin/=end block comment" do
    checkout do |root|
      write(root, "lib/foo/version.rb",
            "=begin\nVERSION = \"9.9.9\"\n=end\nVERSION = \"1.2.3\"\n")
      expect(rules(root, next_version: "1.2.4")).to eq([])
      expect(rules(root, next_version: "1.2.3")).to eq([:version_behind_next])
    end
  end

  it "reads a qualified Foo::VERSION assignment" do
    checkout do |root|
      write(root, "lib/foo/version.rb", "Foo::VERSION = \"1.2.3\"\n")
      expect(rules(root, next_version: "1.2.4")).to eq([])
      expect(rules(root, next_version: "1.2.3")).to eq([:version_behind_next])
    end
  end

  it "reads an inline module Foo; VERSION = ...; end" do
    checkout do |root|
      write(root, "lib/foo/version.rb",
            "module Foo; VERSION = \"1.2.3\"; end\n")
      expect(rules(root, next_version: "1.2.4")).to eq([])
      expect(rules(root, next_version: "1.2.3")).to eq([:version_behind_next])
    end
  end

  it "reads a VERSION literal followed by .freeze" do
    checkout do |root|
      write(root, "lib/foo/version.rb",
            "module Foo\n  VERSION = \"1.2.3\".freeze\nend\n")
      expect(rules(root, next_version: "1.2.4")).to eq([])
      expect(rules(root, next_version: "1.2.3")).to eq([:version_behind_next])
    end
  end

  it "checks the last VERSION assignment, which is the one Ruby loads" do
    checkout do |root|
      write(root, "lib/foo/version.rb",
            "module Foo\n  VERSION = \"1.2.3\"\n  VERSION = \"9.9.9\"\nend\n")
      expect(rules(root, next_version: "9.9.5")).to eq([:version_behind_next])
    end
  end

  it "flags a VERSION reassigned from a non-literal" do
    checkout do |root|
      write(root, "lib/foo/version.rb",
            "module Foo\n  VERSION = \"1.2.3\"\n  VERSION = compute\nend\n")
      expect(rules(root, next_version: "1.2.4")).to eq([:version_behind_next])
    end
  end

  it "flags an empty VERSION string" do
    checkout do |root|
      write(root, "lib/foo/version.rb", "VERSION = \"\"\n")
      messages = described_class.new(root, next_version: "1.2.4")
        .check.map(&:message)
      expect(messages)
        .to eq(["lib/foo/version.rb: \"\" is not a valid version"])
    end
  end

  it "reports a malformed VERSION as a finding instead of raising" do
    checkout do |root|
      write(root, "lib/foo/version.rb", "VERSION = \"abc\"\n")
      expect(rules(root, next_version: "1.2.4")).to eq([:version_behind_next])
    end
  end

  it "accepts YAML anchors and aliases in the release workflow" do
    checkout do |root|
      write(root, ".github/workflows/release.yml", <<~YML)
        on:
          workflow_dispatch:
            inputs: &inputs
              next_version:
                required: true
          repository_dispatch:
            types: [ do-release ]
        jobs:
          release:
            uses: metanorma/ci/.github/workflows/rubygems-release.yml@main
          preflight:
            if: false
            with: *inputs
      YML
      expect(rules(root, next_version: "1.2.4")).to eq([])
    end
  end

  ["false", "${{ false }}"].each do |condition|
    it "flags a reusable release job whose condition is #{condition}" do
      checkout do |root|
        write(root, ".github/workflows/release.yml",
              release_yml.sub("    uses:", "    if: #{condition}\n    uses:"))
        expect(described_class.new(root).check.map(&:message))
          .to include("release.yml does not call the reusable rubygems-release")
      end
    end
  end

  it "reports a checkout that does not exist as a finding" do
    Dir.mktmpdir do |base|
      expect(rules(File.join(base, "gone"), next_version: "1.2.4"))
        .to eq([:checkout])
    end
  end

  it "reads a checkout whose path contains glob brackets" do
    Dir.mktmpdir do |base|
      root = File.join(base, "gem[1]")
      FileUtils.mkdir_p(root)
      Open3.capture2e("git", "init", "-q", chdir: root)
      write(root, "lib/foo/version.rb", "VERSION = \"1.2.3\"\n")
      write(root, ".github/workflows/release.yml", release_yml)
      write(root, ".gitignore", "/Gemfile.lock\n")
      expect(rules(root, next_version: "1.2.4")).to eq([])
    end
  end

  it "reports a malformed next_version as a finding instead of raising" do
    checkout do |root|
      expect(rules(root, next_version: "abc")).to eq([:version_behind_next])
    end
  end
end
