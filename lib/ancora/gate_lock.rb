# frozen_string_literal: true

module Ancora
  # The gate lock: a Gemfile pinning the ENTIRE chain inventory at exact
  # versions - the wave's candidates for the gems under gate, released
  # floors for everything else. Bundler never resolves prereleases
  # implicitly, so multi-level candidate chains must be pinned exactly.
  # External chains (gems outside the inventory) are pinned at their
  # satisfying FINALS when findings are supplied: the gate never
  # validates "latest", and nothing promotes against another chain's
  # prerelease - a need with no satisfying final blocks the lock.
  class GateLock
    SOURCE = "https://rubygems.org"
    # the shape Gem::Version accepts, with no quote or backslash that could end the literal
    PLAIN_VERSION = /\A[0-9]+(\.[0-9a-zA-Z]+)*(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?\z/

    def initialize(chain, graph, externals: [])
      @chain = chain
      @graph = graph
      @externals = externals
    end

    def pins(candidates = {})
      inventory.each_with_object({}) do |gem, pins|
        version = candidates[gem] || released_version(gem)
        pins[gem] = version if version
      end
    end

    # external needs with no satisfying final: the lock cannot complete
    def awaiting
      @externals.select { |f| f.status == :awaiting_release }
    end

    def gemfile(candidates = {})
      pinned = pins(candidates)
      header = [
        "# frozen_string_literal: true",
        "# gate lock: chain #{@chain.name} - exact pins for the whole " \
        "inventory (#{pinned.size} gems)",
        %(source "#{SOURCE}"),
        "",
      ]
      body = pinned.keys.sort.map { |gem| gem_line(gem, pinned[gem]) }
      missing = (inventory - pinned.keys).sort
      body.concat(missing.map { |gem| "# #{gem}: no version on record" })
      body.concat(external_pins)
      body.concat(awaiting.map do |f|
        "# AWAITING RELEASE: #{f.from.join(', ')} -> #{f.gem} " \
          "(#{f.constraints.join(', ')}); latest final #{f.latest_final || 'none'}"
      end)
      (header + body + [""]).join("\n")
    end

    # A suite's Gemfile: the gem's own Gemfile (so its test dependencies
    # are in the bundle) with every gem of the gate pinned exactly. A pinned
    # gem the gem's Gemfile declares from git or a path resolves from
    # rubygems.org at the pin instead; pins it never declares are appended.
    # The gem under test comes from its own checkout, so it is not pinned.
    def suite_gemfile(candidates, own:)
      pinned = all_pins(candidates).except(own)
      <<~RUBY
        # frozen_string_literal: true
        # gate suite overlay: chain #{@chain.name} - #{own} against the gate
        # pins (#{pinned.size} gems), with its own test dependencies
        ancora_pins = #{pinned.sort.to_h.inspect}
        ancora_declared = []
        ancora_source_keys = %i[git github path source branch ref tag submodules glob]
        singleton_class.prepend(Module.new do
          define_method(:gem) do |name, *args|
            pin = ancora_pins[name]
            return super(name, *args) unless pin

            ancora_declared << name
            opts = args.grep(Hash).map do |h|
              h.reject { |k, _| ancora_source_keys.include?(k.to_sym) }
            end
            inherited = @source
            @source = nil
            begin
              super(name, pin, *opts)
            ensure
              @source = inherited
            end
          end
        end)
        source "#{SOURCE}"
        own = File.join(__dir__, "Gemfile")
        File.exist?(own) ? eval_gemfile(own) : gemspec
        (ancora_pins.keys - ancora_declared).each { |name| gem name, ancora_pins[name] }
      RUBY
    end

    private

    def all_pins(candidates)
      externals = @externals.select { |f| f.status == :satisfied }
        .to_h { |f| [f.gem, f.latest_final] }
      externals.merge(pins(candidates)).merge(candidates)
    end

    def gem_line(gem, version)
      raise ArgumentError, "#{gem} pin #{version.inspect} is not a version" unless PLAIN_VERSION.match?(version)

      %(gem "#{gem}", "#{version}")
    end

    def external_pins
      pins = @externals.select { |f| f.status == :satisfied }
        .sort_by(&:gem).map { |f| gem_line(f.gem, f.latest_final) }
      return [] if pins.empty?

      pins.unshift("# external chains - finals (promote-gate truth)")
    end

    def inventory
      @chain.inventory(@graph)
    end

    def released_version(gem)
      node = @graph.nodes[gem]
      node&.released || node&.main_version
    end
  end
end
