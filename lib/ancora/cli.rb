# frozen_string_literal: true

require "optparse"

module Ancora
  # M1 dry-run CLI. Plans waves over collector data and prints them;
  # dispatches nothing, releases nothing.
  #
  #   ancora plan --network network.json --delta delta.json
  #   ancora plan --network network.json --chain chain.yml --seeds gem
  #   ancora pin --chain chain.yml --network network.json --delta delta.json
  #   ancora check metanorma-plugin-lutaml 0.7.54
  #   ancora tag metanorma/metanorma-cli 1.17.0
  #   ancora ci metanorma/metanorma-cli
  class CLI
    def self.run(argv)
      new(argv).run
    end

    def initialize(argv)
      @argv = argv
    end

    def run
      command = @argv.shift
      case command
      when "plan" then plan
      when "pin" then return pin
      when "drift" then drift
      when "externals" then return externals
      when "check" then check
      when "tag" then tag
      when "ci" then ci
      when "step" then return step
      when "approve" then return approve
      else return usage
      end
      0
    end

    private

    def plan
      options = { delta: nil, seeds: [], chain: nil }
      parse_graph_options(options)

      graph = Graph.load(options.fetch(:network), options[:delta])
      chain = load_chain(options)
      scope = options[:seeds].empty? ? :full : :scoped
      waves = Planner.new(graph, chain: chain).plan(scope: scope,
                                                    seeds: options[:seeds])
      if chain
        terminus = chain.terminus(graph)
        label = terminus ? terminus.join(", ") : "none (fan chain)"
        puts "chain: #{chain.name} (terminus: #{label})"
      end
      puts "scope: #{scope} (#{waves.flatten.size} gems, #{waves.size} waves)"
      waves.each_with_index do |wave, i|
        puts "wave #{i + 1}: #{wave.join(', ')}"
      end
    end

    def pin
      options = { delta: nil, seeds: [], chain: nil, externals: nil }
      parse_graph_options(options)

      chain = load_chain(options)
      return 1 unless chain

      graph = Graph.load(options.fetch(:network), options[:delta])
      findings = options[:externals] ? external_findings(chain, graph) : []
      lock = GateLock.new(chain, graph, externals: findings)
      puts lock.gemfile
      unless lock.awaiting.empty?
        lock.awaiting.each { |f| warn "gate lock blocked: #{f.from} -> #{f.gem}" }
        return 1
      end
      0
    end

    def external_findings(chain, graph)
      Externals.new(graph, chain: chain,
                           oracle: Oracle::Rubygems.new).check
    end

    def drift
      options = { delta: nil, seeds: [], chain: nil }
      parse_graph_options(options)

      graph = Graph.load(options.fetch(:network), options[:delta])
      chain = load_chain(options)
      rep = Drift.new(graph, chain: chain).report
      puts "drift report: #{chain ? "chain #{chain.name}" : 'whole fleet'}"
      section(rep.floorless, "floorless edges") do |e|
        "#{e.from} -> #{e.to}"
      end
      section(rep.stale_pins, "stale pins") do |s|
        "#{s.from} -> #{s.to}: #{s.constraints.join(', ')} excludes main #{s.main_version}"
      end
      section(rep.prerelease_floors, "prerelease floors") do |e|
        "#{e.from} -> #{e.to}: #{e.constraints.join(', ')}"
      end
      section(rep.unreleased, "unreleased main") do |u|
        if u.ahead_by
          "#{u.gem}: ahead by #{u.ahead_by}"
        else
          "#{u.gem}: never released (main #{u.main_version})"
        end
      end
    end

    # external-chain needs of a chain: floors pointing outside the
    # inventory, checked against the oracle for satisfying FINALS. A
    # need awaiting release is the cross-chain release-request case.
    def externals
      options = { delta: nil, seeds: [], chain: nil }
      parse_graph_options(options)

      chain = load_chain(options)
      return usage unless chain

      graph = Graph.load(options.fetch(:network), options[:delta])
      findings = Externals.new(graph, chain: chain,
                                      oracle: Oracle::Rubygems.new).check
      puts "external needs of chain #{chain.name} (#{findings.size})"
      satisfied = findings.select { |f| f.status == :satisfied }
      section(satisfied, "satisfied by finals") do |f|
        "#{f.from} -> #{f.gem} (#{f.constraints.join(', ')}): final #{f.latest_final}"
      end
      section(findings - satisfied, "awaiting release (file a request)") do |f|
        "#{f.from} -> #{f.gem} (#{f.constraints.join(', ')}): " \
          "latest final #{f.latest_final || 'none'}"
      end
      satisfied.size == findings.size ? 0 : 1
    end

    def section(items, title)
      puts
      puts "== #{title} (#{items.size})"
      items.each { |item| puts yield(item) }
    end

    def check
      gem = @argv.shift
      version = @argv.shift
      return usage unless gem && version

      oracle = Oracle::Rubygems.new
      state = oracle.published?(gem, version) ? "published" : "NOT published"
      puts "#{gem} #{version}: #{state}"
    end

    # one transition per invocation: the dry-run of the step-per-run
    # state machine. Prints the action a runtime run would execute and
    # commits the manifest cache when --manifest is given. --format json
    # emits the action for the runtime workflow to parse.
    def step
      options = { delta: nil, seeds: [], chain: nil, manifest: nil, format: "text" }
      parse_graph_options(options)

      chain = load_chain(options)
      return 1 unless chain

      graph = Graph.load(options.fetch(:network), options[:delta])
      path = options[:manifest]
      manifest = path ? Manifest.load(path, chain.name) : Manifest.new(chain.name)
      action = Machine.new(chain: chain, graph: graph,
                           oracle: Oracle::Rubygems.new).step(manifest)
      emit(action, manifest, chain, graph, options[:format])
      manifest.write(path) if path
      0
    end

    def emit(action, manifest, chain, graph, format)
      if format == "json"
        puts JSON.generate(action_payload(action).merge(state: manifest.state))
        return
      end

      puts "state: #{manifest.state}"
      if action.is_a?(Machine::Gate)
        render_gate(action, chain, graph, manifest.current_attempt.pins)
      else
        render_action(action)
      end
    end

    # action as plain data for the runtime edge; keys are the workflow's
    # contract with the machine
    def action_payload(action)
      case action
      when Machine::DispatchWave
        { action: "dispatch_wave", index: action.index,
          items: payload_items(action.items) }
      when Machine::Gate
        { action: "gate", attempt_index: action.attempt_index }
      when Machine::PromoteWave
        { action: "promote_wave", index: action.index,
          items: payload_items(action.items) }
      when Machine::Hold then { action: "hold", reason: action.reason }
      when Machine::Halt then { action: "halt", reason: action.reason }
      when Machine::Done then { action: "done" }
      else raise "unknown action #{action.class}"
      end
    end

    def payload_items(items)
      items.map { |i| { gem: i.gem, repo: i.repo, version: i.version } }
    end

    def render_gate(action, chain, graph, pins)
      recipe = GateRecipe.new(chain, graph).build(pins)
      pin_count = recipe.lockfile.lines.count { |l| l.start_with?('gem "') }
      puts "gate attempt #{action.attempt_index}: #{pin_count} exact pins"
      recipe.suites.each do |s|
        cmds = s.commands.empty? ? "(chain declares no suite commands)" : s.commands.join(" && ")
        puts "  suite #{s.gem} (#{s.repo}): #{cmds}"
      end
      recipe.canary.each { |c| puts "  canary: #{c}" }
    end

    def render_action(action)
      case action
      when Machine::DispatchWave
        puts "dispatch wave #{action.index + 1}:"
        action.items.each { |i| puts "  #{i.gem} #{i.version} (#{i.repo})" }
      when Machine::Gate
        puts "gate attempt #{action.attempt_index}: lock the candidate set " \
             "(ancora pin), run suites + canary, then record green/red"
      when Machine::PromoteWave
        puts "promote wave #{action.index + 1} finals:"
        action.items.each { |i| puts "  #{i.gem} #{i.version} (#{i.repo})" }
      when Machine::Hold then puts "HOLD: #{action.reason}"
      when Machine::Halt then puts "HALT: #{action.reason}"
      when Machine::Done then puts "wave done"
      end
    end

    def approve
      options = { manifest: nil }
      OptionParser.new do |o|
        o.on("--manifest PATH") { |v| options[:manifest] = v }
      end.parse!(@argv)
      return usage unless options[:manifest]

      manifest = Manifest.load(options[:manifest])
      manifest.approve!
      manifest.write(options[:manifest])
      puts "chain #{manifest.chain}: wave approved for promotion"
      0
    end

    def tag
      repo = @argv.shift
      version = @argv.shift
      return usage unless repo && version

      oracle = Oracle::Github.new
      state = oracle.tagged_version?(repo, version) ? "tagged" : "NOT tagged"
      puts "#{repo} v#{version}: #{state}"
    end

    def ci
      repo = @argv.shift
      branch = @argv.shift || "main"
      return usage unless repo

      run = Oracle::Github.new.latest_run(repo, branch: branch)
      unless run
        puts "#{repo} #{branch}: no run"
        return
      end

      puts "#{repo} #{branch}: #{run['name']} #{run['conclusion'] || run['status']} " \
           "#{run['head_sha'][0, 8]} #{run['html_url']}"
    end

    def parse_graph_options(options)
      OptionParser.new do |o|
        o.on("--network PATH") { |v| options[:network] = v }
        o.on("--delta PATH") { |v| options[:delta] = v }
        o.on("--seeds a,b,c") { |v| options[:seeds] = v.split(",") }
        o.on("--chain PATH") { |v| options[:chain] = v }
        o.on("--manifest PATH") { |v| options[:manifest] = v }
        o.on("--format F") { |v| options[:format] = v }
        o.on("--externals") { |v| options[:externals] = v }
      end.parse!(@argv)
    end

    def load_chain(options)
      return nil unless options[:chain]

      Chain.load(options[:chain])
    end

    def usage
      warn "usage: ancora plan --network PATH [--delta PATH] [--chain chain.yml] [--seeds a,b]"
      warn "       ancora pin --chain chain.yml --network PATH [--delta PATH]"
      warn "       ancora drift --network PATH [--delta PATH] [--chain chain.yml]"
      warn "       ancora externals --chain chain.yml --network PATH [--delta PATH]"
      warn "       ancora check GEM VERSION"
      warn "       ancora tag OWNER/REPO VERSION"
      warn "       ancora ci OWNER/REPO [BRANCH]"
      warn "       ancora step --chain chain.yml --network PATH --delta PATH [--manifest PATH]"
      warn "       ancora approve --manifest PATH"
      1
    end
  end
end
