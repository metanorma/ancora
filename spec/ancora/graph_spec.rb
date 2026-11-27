# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Ancora::Graph do
  def network(constraints)
    {
      "lutaml/ea" => { "name" => "ea", "main_version" => "0.6.41",
                       "deps" => [{ "name" => "xmi",
                                    "constraints" => constraints }] },
      "lutaml/xmi" => { "name" => "xmi", "main_version" => "0.7.6",
                        "deps" => [] },
    }
  end

  it "reads a dependency with no constraints as having none" do
    edge = described_class.from_data(network(nil), {}).edges.first
    expect(edge.constraints).to eq []
  end

  it "refuses constraints that are not a list, naming the edge" do
    expect { described_class.from_data(network(5), {}) }
      .to raise_error(ArgumentError, /ea -> xmi: constraints must be a list/)
  end

  it "refuses a network file that is a list, not an object" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "network.json")
      File.write(path, "[]")
      expect { described_class.load(path) }
        .to raise_error(described_class::Invalid, /must be a JSON object/)
    end
  end
end
