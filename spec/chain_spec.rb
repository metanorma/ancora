# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Ancora::Chain do
  let(:graph) { Ancora::Graph.from_data(FleetFixture::NETWORK, FleetFixture::DELTA) }

  def chain(yaml)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "chain.yml")
      File.write(path, yaml)
      yield described_class.load(path)
    end
  end

  it "resolves the metanorma chain inventory to the terminus closure within the org" do
    chain(FleetFixture::METANORMA_CHAIN) do |c|
      expect(c.name).to eq "metanorma"
      expect(c.inventory(graph)).to eq(
        ["metanorma-cli", "metanorma-document", "metanorma-plugin-lutaml",
         "metanorma-standoc"],
      )
    end
  end

  it "keeps org gems outside the root closure out of the inventory" do
    chain(FleetFixture::METANORMA_CHAIN) do |c|
      expect(c.inventory(graph)).not_to include("cimas")
      expect(c.inventory(graph)).not_to include("ea")
    end
  end

  it "resolves the lutaml chain inventory to the whole org fan" do
    chain(FleetFixture::LUTAML_CHAIN) do |c|
      expect(c.inventory(graph)).to eq(
        %w[canon ea lutaml lutaml-model lutaml-uml xmi],
      )
      expect(c.terminus(graph)).to be_nil
    end
  end

  it "models the relaton monorepo as one unit shipping both gems" do
    chain(FleetFixture::RELATON_CHAIN) do |c|
      expect(c.inventory(graph)).to eq(%w[pubid relaton relaton-cli])
      units = c.units(graph)
      expect(units.map(&:gems)).to contain_exactly(%w[pubid],
                                                   %w[relaton relaton-cli])
      # the terminus expands through its unit: relaton-cli pins the pair
      expect(c.terminus(graph)).to eq(%w[relaton relaton-cli])
    end
  end

  it "resolves the glossarist chain to its single gem" do
    chain(FleetFixture::GLOSSARIST_CHAIN) do |c|
      expect(c.inventory(graph)).to eq(["glossarist"])
      expect(c.terminus(graph)).to eq(["glossarist"])
      expect(c.units(graph).map(&:gems)).to eq([["glossarist"]])
    end
  end

  it "keeps explicit gems in the inventory even without a graph node" do
    trimmed = FleetFixture::NETWORK.except("glossarist/glossarist")
    nodeless = Ancora::Graph.from_data(trimmed, FleetFixture::DELTA)
    chain(FleetFixture::GLOSSARIST_CHAIN) do |c|
      expect(c.inventory(nodeless)).to eq(["glossarist"])
    end
  end

  it "parses the gate, canary, and promote-approval runtime surface" do
    chain(FleetFixture::METANORMA_CHAIN) do |c|
      expect(c.gate_commands).to eq(["bundle exec rspec"])
      expect(c.canary_commands).to eq(["bundle exec rake site"])
      expect(c.promote_approval).to eq "none"
    end
  end

  it "merges corpora across gated gems, keeping per-repo gems" do
    chain(FleetFixture::METANORMA_CHAIN) do |c|
      corpora = c.corpora_for(%w[metanorma-iso metanorma-cli])
      expect(corpora.map(&:repo)).to eq(
        ["metanorma/mn-samples-iso", "metanorma/mn-samples-iso-private",
         "metanorma/mn-samples-jis"],
      )
      iso_private = corpora.find do |e|
        e.repo == "metanorma/mn-samples-iso-private"
      end
      expect(iso_private.gems).to eq(%w[metanorma-cli metanorma-iso])
      expect(iso_private.budget).to eq 600
      expect(corpora.find { |e| e.repo == "metanorma/mn-samples-iso" }.documents)
        .to eq(["ISO 10303-2"])
    end
  end

  it "defaults corpus ref and applies only to requested gems" do
    chain(FleetFixture::METANORMA_CHAIN) do |c|
      iso = c.corpora_for(["metanorma-iso"]).find do |e|
        e.repo == "metanorma/mn-samples-iso-private"
      end
      expect(iso.ref).to eq "main"
      expect(iso.gems).to eq(["metanorma-iso"])
      expect(c.corpora_for(["metanorma-document"])).to be_empty
    end
  end

  it "rejects malformed corpus entries" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "chain.yml")
      File.write(path, "name: x\ncanary:\n  corpora:\n    gem-a:\n      ref: main\n")
      expect { described_class.load(path) }
        .to raise_error(Ancora::Chain::ConfigError, /list of entries/)

      File.write(path, "name: x\ncanary:\n  corpora:\n    gem-a:\n      - ref: main\n")
      expect { described_class.load(path) }
        .to raise_error(Ancora::Chain::ConfigError, %r{requires repo:})

      File.write(path, "name: x\ncanary:\n  corpora:\n    gem-a:\n      - repo: r/c\n        budget: lots\n")
      expect { described_class.load(path) }
        .to raise_error(Ancora::Chain::ConfigError, /budget/)

      File.write(path, "name: x\ncanary:\n  corpora:\n    gem-a:\n      - repo: r/c\n        flavor: x\n")
      expect { described_class.load(path) }
        .to raise_error(Ancora::Chain::ConfigError, /unknown key/)
    end
  end

  it "defaults promote approval to manual (the guardrail)" do
    chain(FleetFixture::LUTAML_CHAIN) do |c|
      expect(c.promote_approval).to eq "manual"
      expect(c.gate_commands).to be_empty
      expect(c.canary_commands).to be_empty
    end
  end

  it "rejects unknown gate keys and bad approval values" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "chain.yml")
      File.write(path, "name: x\ngate:\n  commandz: []\n")
      expect { described_class.load(path) }
        .to raise_error(Ancora::Chain::ConfigError, /unknown key/)

      File.write(path, "name: x\npromote_approval: maybe\n")
      expect { described_class.load(path) }
        .to raise_error(Ancora::Chain::ConfigError, /promote_approval/)
    end
  end

  it "rejects the same corpus declared differently across gems" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "chain.yml")
      File.write(path, <<~YAML)
        name: x
        canary:
          corpora:
            gem-a:
              - repo: r/c
                budget: 300
            gem-b:
              - repo: r/c
                budget: 600
      YAML
      expect { described_class.load(path) }
        .to raise_error(Ancora::Chain::ConfigError, %r{r/c declared differently})
    end
  end

  it "rejects a terminus outside the inventory" do
    chain("name: metanorma\ninventory:\n  orgs: [metanorma]\nterminus: [lutaml]\n") do |c|
      expect { c.terminus(graph) }
        .to raise_error(Ancora::Chain::ConfigError,
                        /terminus lutaml is not in the inventory/)
    end
  end

  it "rejects excluding a monorepo member" do
    yaml = <<~YAML
      name: relaton
      inventory:
        orgs: [relaton]
        exclude: [relaton]
      monorepos:
        relaton/relaton-cli: [relaton, relaton-cli]
      terminus: [relaton-cli]
    YAML
    chain(yaml) do |c|
      expect { c.inventory(graph) }
        .to raise_error(Ancora::Chain::ConfigError,
                        /excluded from their monorepo unit/)
    end
  end

  it "rejects unknown config keys" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "chain.yml")
      File.write(path, "name: metanorma\ninventori:\n  orgs: [metanorma]\n")
      expect { described_class.load(path) }
        .to raise_error(Ancora::Chain::ConfigError, /unknown key/)
    end
  end
end
