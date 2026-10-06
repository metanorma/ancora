# frozen_string_literal: true

# A real-shaped slice of all four fleets (metanorma, lutaml, relaton,
# glossarist) as one collector dataset, mirroring LOCKCHAIN.md: the
# metanorma chain culminates in metanorma-cli; lutaml is a fan (the
# lutaml gem covers only part of the org, ea feeds metanorma instead);
# relaton/relaton-cli is a monorepo whose root gemspec names only
# relaton-cli; glossarist is a single-gem library chain.
module FleetFixture
  NETWORK = {
    "metanorma/metanorma-cli" => {
      "name" => "metanorma-cli", "main_version" => "1.17.0",
      "deps" => [{ "name" => "metanorma-standoc", "constraints" => ["~> 3.5.0"] }]
    },
    "metanorma/metanorma-standoc" => {
      "name" => "metanorma-standoc", "main_version" => "3.5.0",
      "deps" => [
        { "name" => "metanorma-plugin-lutaml", "constraints" => ["~> 0.7.31"] },
        { "name" => "metanorma-document", "constraints" => ["~> 0.5.0"] },
        { "name" => "relaton-cli", "constraints" => ["~> 3.0"] },
      ]
    },
    "metanorma/metanorma-document" => {
      "name" => "metanorma-document", "main_version" => "0.5.1",
      "deps" => [
        { "name" => "glossarist", "constraints" => ["~> 2.14.1"] },
        { "name" => "sts", "constraints" => [">= 0.5"] },
      ]
    },
    "metanorma/metanorma-plugin-lutaml" => {
      "name" => "metanorma-plugin-lutaml", "main_version" => "0.7.54",
      "deps" => [{ "name" => "ea", "constraints" => [">= 0.6.41"] }]
    },
    "metanorma/isodoc" => {
      "name" => "isodoc", "main_version" => "3.7.3",
      "deps" => [{ "name" => "isodoc-i18n", "constraints" => ["~> 1.1.0"] }]
    },
    "metanorma/isodoc-i18n" => {
      "name" => "isodoc-i18n", "main_version" => "1.5.3", "deps" => []
    },
    "metanorma/xseed" => {
      "name" => "xseed", "main_version" => "1.0.0", "deps" => []
    },
    "metanorma/cimas" => {
      "name" => "cimas", "main_version" => "0.3.0", "deps" => []
    },
    "lutaml/lutaml" => {
      "name" => "lutaml", "main_version" => "0.11.4",
      "deps" => [
        { "name" => "lutaml-model", "constraints" => [] },
        { "name" => "lutaml-uml", "constraints" => [] },
      ]
    },
    "lutaml/lutaml-model" => {
      "name" => "lutaml-model", "main_version" => "0.8.94",
      "deps" => [{ "name" => "canon", "constraints" => [] }]
    },
    "lutaml/canon" => { "name" => "canon", "main_version" => "0.3.77",
                        "deps" => [] },
    "lutaml/lutaml-uml" => { "name" => "lutaml-uml", "main_version" => "1.0.2",
                             "deps" => [] },
    "lutaml/ea" => {
      "name" => "ea", "main_version" => "0.6.41",
      "deps" => [{ "name" => "xmi", "constraints" => ["~> 0.7"] }]
    },
    "lutaml/xmi" => {
      "name" => "xmi", "main_version" => "0.7.6",
      "deps" => [{ "name" => "lutaml-model", "constraints" => [] }]
    },
    "relaton/relaton-cli" => {
      "name" => "relaton-cli", "main_version" => "3.0.0.pre.alpha.4",
      "deps" => [{ "name" => "pubid", "constraints" => ["~> 2.0.0.pre.alpha"] }]
    },
    "pubid/pubid" => {
      "name" => "pubid", "main_version" => "2.0.0.pre.alpha.27",
      "deps" => [{ "name" => "parsanol", "constraints" => [] }]
    },
    "glossarist/glossarist" => {
      "name" => "glossarist", "main_version" => "2.14.1", "deps" => []
    },
  }.freeze

  DELTA = {
    "metanorma/metanorma-cli" => {
      "gem" => "metanorma-cli", "main_version" => "1.17.0",
      "released" => "1.17.0", "ahead_by" => 0
    },
    "metanorma/metanorma-standoc" => {
      "gem" => "metanorma-standoc", "main_version" => "3.5.1",
      "released" => "3.5.0", "ahead_by" => 65
    },
    "metanorma/metanorma-document" => {
      "gem" => "metanorma-document", "main_version" => "0.5.2",
      "released" => "0.5.1", "ahead_by" => 131
    },
    "metanorma/metanorma-plugin-lutaml" => {
      "gem" => "metanorma-plugin-lutaml", "main_version" => "0.7.54",
      "released" => "0.7.54", "ahead_by" => 0
    },
    "metanorma/cimas" => {
      "gem" => "cimas", "main_version" => "0.3.0", "released" => "0.3.0", "ahead_by" => 0
    },
    "lutaml/ea" => {
      "gem" => "ea", "main_version" => "0.6.42", "released" => "0.6.41", "ahead_by" => 2
    },
    "lutaml/xmi" => {
      "gem" => "xmi", "main_version" => "0.7.7", "released" => "0.7.6", "ahead_by" => 2
    },
    "relaton/relaton-cli" => {
      "gem" => "relaton-cli", "main_version" => "3.0.0.pre.alpha.5",
      "released" => "3.0.0.pre.alpha.4", "ahead_by" => 3
    },
    "pubid/pubid" => {
      "gem" => "pubid", "main_version" => "2.0.0.pre.alpha.28",
      "released" => "2.0.0.pre.alpha.27", "ahead_by" => 1
    },
    "glossarist/glossarist" => {
      "gem" => "glossarist", "main_version" => "2.15.0",
      "released" => "2.14.1", "ahead_by" => 9
    },
  }.freeze

  METANORMA_CHAIN = <<~YAML
    name: metanorma
    inventory:
      orgs: [metanorma]
      roots: [metanorma-cli]
    terminus: [metanorma-cli]
    gate:
      commands: [bundle exec rspec]
    canary:
      commands: [bundle exec rake site]
      corpora:
        metanorma-iso:
          - repo: metanorma/mn-samples-iso
            ref: main
            documents: [ISO 10303-2]
            budget: 300
          - repo: metanorma/mn-samples-iso-private
            budget: 600
        metanorma-cli:
          - repo: metanorma/mn-samples-iso-private
            budget: 600
          - repo: metanorma/mn-samples-jis
            budget: 240
    promote_approval: none
  YAML

  LUTAML_CHAIN = <<~YAML
    name: lutaml
    inventory:
      orgs: [lutaml]
  YAML

  RELATON_CHAIN = <<~YAML
    name: relaton
    inventory:
      orgs: [relaton, pubid]
    monorepos:
      relaton/relaton-cli: [relaton, relaton-cli]
    terminus: [relaton-cli]
  YAML

  GLOSSARIST_CHAIN = <<~YAML
    name: glossarist
    inventory:
      gems: [glossarist]
    terminus: [glossarist]
    promote_approval: none
  YAML

  # Loads a chain.yml from its text, for specs that vary the config.
  def self.load_chain(yaml)
    Tempfile.create(["chain", ".yml"]) do |f|
      f.write(yaml)
      f.flush
      return Ancora::Chain.load(f.path)
    end
  end
end
