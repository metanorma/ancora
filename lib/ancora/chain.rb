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
    # one corpus run gating a set of gems; the engine only enforces the
    # CONFIGURED corpora - it never infers coverage
    CorpusEntry = Struct.new(:repo, :ref, :documents, :budget, :gems,
                             keyword_init: true)

    TOP_LEVEL_KEYS = %w[name inventory monorepos terminus max_attempts gate canary
                        promote_approval].freeze
    INVENTORY_KEYS = %w[orgs roots gems exclude].freeze
    APPROVAL_MODES = %w[manual none].freeze
    CORPUS_ENTRY_KEYS = %w[repo ref documents budget].freeze
    DEFAULT_CORPUS_BUDGET = 600

    def self.load(path)
      data = YAML.safe_load(File.read(path),
                            permitted_classes: [], aliases: false)
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
        gate_commands: commands(path, "gate", data["gate"]),
        canary_commands: canary_commands(path, data["canary"]),
        corpora: corpora(path, data.dig("canary", "corpora")),
        promote_approval: promote_approval(path, data["promote_approval"]),
      )
    end

    def self.max_attempts(path, value)
      return nil if value.nil?
      unless value.is_a?(Integer) && value.positive?
        raise ConfigError, "#{path}: max_attempts must be a positive integer"
      end

      value
    end

    def self.commands(path, section, value)
      return [] if value.nil?
      unless value.is_a?(Hash)
        raise ConfigError, "#{path}: #{section} must be a mapping"
      end

      reject_unknown_keys("#{path}: #{section}:", value.keys, ["commands"])
      string_array("#{path}: #{section}: commands", value["commands"])
    end

    def self.canary_commands(path, value)
      return [] if value.nil?
      unless value.is_a?(Hash)
        raise ConfigError, "#{path}: canary must be a mapping"
      end

      reject_unknown_keys("#{path}: canary:", value.keys, %w[commands corpora])
      string_array("#{path}: canary: commands", value["commands"])
    end

    # the corpora gate: gem -> corpus runs that gate that gem's waves
    def self.corpora(path, value)
      return {} if value.nil?
      unless value.is_a?(Hash) && value.values.all?(Array)
        raise ConfigError, "#{path}: canary corpora must map gem -> list of entries"
      end

      entries = value.to_h do |gem, list|
        [gem.to_s, list.map { |e| corpus_entry(path, gem.to_s, e) }]
      end
      reject_corpus_conflicts(entries)
      entries
    end

    # a corpus run is per-repo: the same repo listed under different
    # gems must carry the same ref/documents/budget, or the run is
    # ambiguous - the config owner must decide
    def self.reject_corpus_conflicts(entries)
      entries.values.flatten.group_by(&:repo).each do |repo, group|
        next if group.map { |e| [e.ref, e.documents, e.budget] }.uniq.one?

        raise ConfigError, "canary corpora: #{repo} declared differently " \
                           "across gems"
      end
    end

    def self.corpus_entry(path, gem, value)
      where = "#{path}: canary: corpora: #{gem}:"
      unless value.is_a?(Hash)
        raise ConfigError, "#{where} must be a mapping"
      end

      reject_unknown_keys(where, value.keys, CORPUS_ENTRY_KEYS)
      repo = value["repo"]
      raise ConfigError, "#{where} requires repo:" unless repo.is_a?(String)

      budget = value.fetch("budget", DEFAULT_CORPUS_BUDGET)
      unless budget.is_a?(Integer) && budget.positive?
        raise ConfigError, "#{where} budget must be a positive integer"
      end

      CorpusEntry.new(repo: repo, ref: value.fetch("ref", "main"),
                      documents: string_array("#{where} documents",
                                              value["documents"]),
                      budget: budget, gems: [gem])
    end

    def self.promote_approval(path, value)
      return "manual" if value.nil? # the guardrail: no finals without approval
      return value if APPROVAL_MODES.include?(value)

      raise ConfigError, "#{path}: promote_approval must be one of " \
                         "#{APPROVAL_MODES.join(', ')}"
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
                         :max_attempts, :commands, :canary_commands, :corpora,
                         :corpus_entry, :reject_corpus_conflicts,
                         :promote_approval

    # how many gate attempts a wave gets before the machine halts for
    # humans; nil falls back to the machine default
    attr_reader :name, :orgs, :roots, :gems, :exclude, :monorepos,
                :max_attempts, :gate_commands, :canary_commands, :corpora

    def promote_approval
      @promote_approval
    end

    def initialize(name:, orgs: [], roots: [], gems: [], exclude: [], monorepos: {},
                   terminus: [], max_attempts: nil, gate_commands: [],
                   canary_commands: [], corpora: {}, promote_approval: "manual")
      @name = name
      @orgs = orgs.freeze
      @roots = roots.freeze
      @gems = gems.freeze
      @exclude = exclude.freeze
      @monorepos = monorepos.freeze
      @terminus_gems = terminus.freeze
      @max_attempts = max_attempts
      @gate_commands = gate_commands.freeze
      @canary_commands = canary_commands.freeze
      @corpora = corpora.freeze
      @promote_approval = promote_approval
    end

    # The corpus runs gating the given gems, merged per repo: gems that
    # share a corpus are unioned into one entry. The terminus union is
    # whatever the config lists for the terminus gem - the engine never
    # infers coverage.
    def corpora_for(gems)
      grouped = Hash.new { |h, k| h[k] = [] }
      gems.each do |gem|
        (@corpora[gem] || []).each { |entry| grouped[entry.repo] << [entry, gem] }
      end
      grouped.map do |repo, pairs|
        first = pairs.first.first
        CorpusEntry.new(repo: repo, ref: first.ref, documents: first.documents,
                        budget: first.budget,
                        gems: pairs.map(&:last).uniq.sort)
      end.sort_by(&:repo)
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
