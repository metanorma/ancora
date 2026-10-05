# frozen_string_literal: true

module Ancora
  # The per-chain configuration (chain.yml): the entire customization
  # surface of the orchestrator - nothing org-specific lives in the
  # engine. Inventory selects the managed gems from the fleet graph
  # (org pool, optionally restricted to root closures, plus explicit
  # gems), monorepos group a repo's gems into one release unit, and
  # terminus is the gem or gem set a wave must culminate in.
  #
  # Chains need not share a shape: metanorma ends in metanorma-cli;
  # relaton ends in a monorepo unit (relaton + relaton-cli from one
  # repo); glossarist is a single-gem library chain; lutaml is a fan
  # with no terminus (the lutaml gem covers only part of the org - the
  # rest feeds external chains - so no terminus is declared).
  class Chain
    class ConfigError < StandardError; end

    Unit = Struct.new(:repo, :gems, keyword_init: true)

    TOP_LEVEL_KEYS = %w[name inventory monorepos terminus max_attempts].freeze
    INVENTORY_KEYS = %w[orgs roots gems exclude].freeze

    def self.load(path)
      data = YAML.safe_load_file(path, permitted_classes: [],
                                       aliases: false)
      unless data.is_a?(Hash)
        raise ConfigError,
              "#{path}: expected a mapping at the top level"
      end

      reject_unknown_keys("#{path}:", data.keys, TOP_LEVEL_KEYS)
      inv = data["inventory"] || {}
      unless inv.is_a?(Hash)
        raise ConfigError,
              "#{path}: inventory must be a mapping (got #{inv.class})"
      end

      reject_unknown_keys("#{path}: inventory:", inv.keys, INVENTORY_KEYS)
      new(
        name: data.fetch("name") { raise ConfigError, "#{path}: missing name" },
        orgs: string_array("#{path}: inventory: orgs", inv["orgs"]),
        roots: string_array("#{path}: inventory: roots", inv["roots"]),
        gems: string_array("#{path}: inventory: gems", inv["gems"]),
        exclude: string_array("#{path}: inventory: exclude", inv["exclude"]),
        monorepos: monorepos(path, data["monorepos"]),
        terminus: string_array("#{path}: terminus", data["terminus"]),
        max_attempts: max_attempts(path, data["max_attempts"]),
      )
    end

    def self.max_attempts(path, value)
      return nil if value.nil?
      unless value.is_a?(Integer) && value.positive?
        raise ConfigError, "#{path}: max_attempts must be a positive integer"
      end

      value
    end

    def self.reject_unknown_keys(where, keys, allowed)
      unknown = keys - allowed
      return if unknown.empty?

      raise ConfigError, "#{where} unknown key(s): #{unknown.join(', ')}"
    end

    def self.string_array(where, value)
      return [] if value.nil?
      unless value.is_a?(Array) && value.all?(String)
        raise ConfigError, "#{where} must be a list of gem names"
      end

      value
    end

    def self.monorepos(path, value)
      return {} if value.nil?
      unless value.is_a?(Hash) && value.values.all?(Array)
        raise ConfigError, "#{path}: monorepos must map repo -> list of gems"
      end

      value.to_h do |repo, gems|
        [repo, string_array("#{path}: monorepos:", gems)]
      end
    end
    private_class_method :reject_unknown_keys, :string_array, :monorepos,
                         :max_attempts

    # how many gate attempts a wave gets before the machine halts for
    # humans; nil falls back to the machine default
    attr_reader :name, :orgs, :roots, :gems, :exclude, :monorepos, :max_attempts

    def initialize(name:, orgs: [], roots: [], gems: [], exclude: [], monorepos: {},
                   terminus: [], max_attempts: nil)
      @name = name
      @orgs = orgs.freeze
      @roots = roots.freeze
      @gems = gems.freeze
      @exclude = exclude.freeze
      @monorepos = monorepos.freeze
      @terminus_gems = terminus.freeze
      @max_attempts = max_attempts
    end

    # The gems this chain manages and pins as a whole, resolved against
    # the fleet graph. Monorepo members are inventory by declaration,
    # even when the collector only sees the repo's root gemspec.
    def inventory(graph)
      conflict = @exclude & @monorepos.values.flatten.uniq
      unless conflict.empty?
        raise ConfigError,
              "gem(s) #{conflict.join(', ')} are excluded from their monorepo unit"
      end

      pool = graph.nodes.values
        .select { |n| @orgs.any? { |o| n.repo.to_s.start_with?("#{o}/") } }
        .map(&:name)
      pool &= closure(graph, @roots) unless @roots.empty?
      ((pool + @gems + @monorepos.values.flatten).uniq - @exclude).sort
    end

    # Release units: a monorepo's gems move as one (the wave versions
    # the repo, not each gem); everything else is a singleton unit.
    def units(graph)
      inv = inventory(graph)
      declared = @monorepos.keys.map do |repo|
        Unit.new(repo: repo, gems: (@monorepos[repo] & inv).sort)
      end
      grouped = declared.flat_map(&:gems)
      singles = (inv - grouped).map do |gem|
        Unit.new(repo: graph.nodes[gem]&.repo || gem, gems: [gem])
      end
      (declared + singles).sort_by(&:repo)
    end

    # The terminus gem set, expanded through monorepo units: declaring
    # relaton-cli makes the whole relaton/relaton-cli unit the terminus.
    # Nil means a fan chain with no terminus.
    def terminus(graph)
      return nil if @terminus_gems.empty?

      inv = inventory(graph)
      outside = @terminus_gems - inv
      unless outside.empty?
        raise ConfigError,
              "terminus #{outside.join(', ')} is not in the inventory of chain #{name}"
      end

      units(graph).select { |u| (u.gems & @terminus_gems).any? }
        .flat_map(&:gems).uniq.sort
    end

    private

    def closure(graph, roots)
      seen = {}
      frontier = roots.dup
      until frontier.empty?
        gem = frontier.pop
        next if seen[gem]

        seen[gem] = true
        frontier.concat(graph.dependencies_of(gem))
      end
      seen.keys
    end
  end
end
