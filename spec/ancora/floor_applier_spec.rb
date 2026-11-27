# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Ancora::FloorApplier do
  let(:graph) do
    Ancora::Graph.from_data(
      { "org/app" => { "name" => "app", "main_version" => "1.0.0",
                       "deps" => [{ "name" => "dep", "constraints" => [] }] },
        "org/dep" => { "name" => "dep", "main_version" => "1.4.0",
                       "deps" => [] } },
      { "org/dep" => { "gem" => "dep", "main_version" => "1.4.0",
                       "released" => "1.4.0", "ahead_by" => 0 } },
    )
  end
  let(:fixes) { Ancora::FloorFixer.new(graph).plan.fixes }

  def write_gemspec(root, body)
    path = File.join(root, "app", "app.gemspec")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, body)
    path
  end

  it "patches the gemspec in the checkout and is idempotent" do
    Dir.mktmpdir do |root|
      path = write_gemspec(root, %(  spec.add_dependency "dep"\n))

      first = described_class.new(graph, root: root).apply(fixes)
      second = described_class.new(graph, root: root).apply(fixes)

      expect(first.map(&:status)).to eq [:patched]
      expect(File.read(path))
        .to eq(%(  spec.add_dependency "dep", ">= 1.4.0"\n))
      expect(second.map(&:status)).to eq [:unchanged]
    end
  end

  it "patches a gemspec that is not valid UTF-8 and keeps its other bytes" do
    stale = Ancora::Graph.from_data(
      { "org/app" => { "name" => "app", "main_version" => "1.0.0",
                       "deps" => [{ "name" => "dep",
                                    "constraints" => ["~> 1.2.0"] }] },
        "org/dep" => { "name" => "dep", "main_version" => "1.4.0",
                       "deps" => [] } },
      { "org/dep" => { "gem" => "dep", "main_version" => "1.4.0",
                       "released" => "1.4.0", "ahead_by" => 0 } },
    )
    Dir.mktmpdir do |root|
      body = "# caf\xE9\n  spec.add_dependency \"dep\", \"~> 1.2.0\"\n".b
      path = write_gemspec(root, body)
      outcomes = described_class.new(stale, root: root)
        .apply(Ancora::FloorFixer.new(stale).plan.fixes)

      expect(outcomes.map(&:status)).to eq [:patched]
      expect(File.binread(path))
        .to eq "# caf\xE9\n  spec.add_dependency \"dep\", \">= 1.4.0\"\n".b
    end
  end

  it "reports a missing gemspec without writing anything" do
    Dir.mktmpdir do |root|
      outcome = described_class.new(graph, root: root).apply(fixes).first

      expect(outcome.status).to eq :no_gemspec
      expect(Dir.children(root)).to be_empty
    end
  end

  it "reports an unpatchable declaration and leaves the file as it was" do
    Dir.mktmpdir do |root|
      body = %(  spec.add_dependency "dep", ["~> 1"]\n)
      path = write_gemspec(root, body)

      outcome = described_class.new(graph, root: root).apply(fixes).first

      expect(outcome.status).to eq :unpatchable
      expect(File.read(path)).to eq body
    end
  end
end
