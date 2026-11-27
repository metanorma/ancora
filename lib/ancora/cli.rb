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
  #   ancora floors --network network.json --chain chain.yml [--root DIR --apply]
  #   ancora gate --chain chain.yml --network network.json --manifest waves.json
  class CLI
    APPLIED = %i[patched unchanged].freeze

    def self.run(argv, shell: Shell.new)
      new(argv, shell: shell).run
    rescue Manifest::Invalid, ArgumentError => e
      warn "ancora: #{e.message}"
      2
    end

    def initialize(argv, shell: Shell.new)
      @argv = argv
      @shell = shell
    end

    def run
      command = @argv.shift
      case command
      when "plan" then plan
      when "pin" then return pin
      when "drift" then drift
      when "drift-report" then return drift_report
      when "externals" then return externals
      when "check" then check
      when "tag" then tag
      when "ci" then ci
      when "step" then return step
      when "approve" then return approve
      when "policy" then return policy
      when "notes" then return notes
      when "floors" then return floors
      when "gate" then return gate
      else return usage
      end
      0
    end

    private

    def plan
      options = { delta: nil, seeds: [], chain: nil, semantic: false }
      parse_graph_options(options)

      graph = Graph.load(options.fetch(:network), options[:delta])
      chain = load_chain(options)
      scope = options[:seeds].empty? ? :full : :scoped
      planner = Planner.new(graph, chain: chain)
      waves = planner.plan(scope: scope, seeds: options[:seeds],
                           semantic: options[:semantic])
      if chain
        terminus = chain.terminus(graph)
        label = terminus ? terminus.join(", ") : "none (fan chain)"
        puts "chain: #{chain.name} (terminus: #{label})"
      end
      puts "scope: #{scope} (#{waves.flatten.size} gems, #{waves.size} waves)"
      waves.each_with_index do |wave, i|
        puts "wave #{i + 1}: #{wave.join(', ')}"
      end
      return unless options[:semantic]

      section(planner.floorless_binding(waves.flatten),
              "floorless edges still ordering the plan") do |e|
        "#{e.from} -> #{e.to}"
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
        lock.awaiting.each { |f| warn "gate lock blocked: #{f.from.join(', ')} -> #{f.gem}" }
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

    # the weekly fleet drift report: markdown on stdout; with --issue
    # also filed as a GitHub issue (needs GITHUB_TOKEN or GH_TOKEN);
    # --tags adds the git-tag check (one GitHub API call per gem)
    def drift_report
      options = { delta: nil, seeds: [], chain: nil }
      parse_graph_options(options)
      return usage unless options[:network] && options[:delta]

      missing = options.values_at(:network, :delta).reject { |f| File.file?(f) }
      unless missing.empty?
        warn "drift-report: no such file: #{missing.join(', ')}"
        return 1
      end

      doc = build_drift_doc(options)
      puts doc.body
      options[:issue] ? file_drift_issue(doc, options[:issue]) : 0
    end

    def build_drift_doc(options)
      graph = Graph.load(options.fetch(:network), options[:delta])
      chain = load_chain(options)
      tags = options[:tags] ? Oracle::Github.new : nil
      report = FleetDrift.new(graph, chain: chain, tags: tags).report
      DriftReport.new(report, scope: chain ? "chain #{chain.name}" : DriftReport::WHOLE_FLEET)
    end

    def file_drift_issue(doc, repo)
      token = github_token
      unless token
        warn "drift-report --issue needs GITHUB_TOKEN or GH_TOKEN"
        return 1
      end
      url = IssueSink.new(repo, token: token)
        .publish(title: doc.title, body: doc.body, label: DriftReport::LABEL)
      warn "issue: #{url}"
      0
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
        "#{f.from.join(', ')} -> #{f.gem} (#{f.constraints.join(', ')}): " \
          "final #{f.latest_final}"
      end
      section(findings - satisfied, "awaiting release (file a request)") do |f|
        "#{f.from.join(', ')} -> #{f.gem} (#{f.constraints.join(', ')}): " \
          "latest final #{f.latest_final || 'none'}"
      end
      satisfied.size == findings.size ? 0 : 1
    end

    # floor-pin fixing: plans (and with --apply performs) gemspec edits
    # for floorless, prerelease and stale floors, against released finals.
    # Edits files under --root only; never commits, pushes or releases.
    # Exits 1 while fixes remain pending or unpatchable.
    def floors
      options = { delta: nil, seeds: [], chain: nil }
      parse_graph_options(options)
      return usage if options[:apply] && !options[:root]

      graph = Graph.load(options.fetch(:network), options[:delta])
      plan = FloorFixer.new(graph, chain: load_chain(options)).plan
      puts "floor fixes: #{plan.fixes.size} fixable, #{plan.skipped.size} skipped"
      section(plan.fixes, "fixable") do |f|
        "#{f.from} -> #{f.to} [#{f.kind}]: #{f.constraints.join(', ').then { |c| c.empty? ? '(none)' : c }} => #{f.proposed.join(', ')}"
      end
      section(plan.skipped, "skipped") do |k|
        "#{k.from} -> #{k.to} [#{k.kind}]: #{k.reason}"
      end
      return plan.fixes.empty? ? 0 : 1 unless options[:apply]

      apply_floors(graph, plan, options[:root])
    end

    def apply_floors(graph, plan, root)
      outcomes = FloorApplier.new(graph, root: root).apply(plan.fixes)
      section(outcomes, "applied") do |o|
        "#{o.fix.from} -> #{o.fix.to}: #{o.status}#{" (#{o.path})" if o.path}"
      end
      outcomes.all? { |o| APPLIED.include?(o.status) } ? 0 : 1
    end

    # canary gating: GateLock full-set compile plus the canary over the
    # configured corpora, for the manifest's open gating attempt. Records
    # the verdict only with --record. Exit 0 green, 1 red.
    def gate
      options = { delta: nil, seeds: [], chain: nil, workdir: ".ancora-gate" }
      parse_graph_options(options)
      chain = load_chain(options)
      return usage unless chain && options[:manifest]

      manifest = Manifest.load(options[:manifest], chain.name)
      refusal = gate_refusal(manifest, chain)
      return refusal if refusal

      graph = Graph.load(options.fetch(:network), options[:delta])
      verdict = run_gate(chain, graph, manifest, options)
      render_verdict(verdict, manifest.current_attempt.index)
      record_verdict(manifest, verdict, options[:manifest]) if options[:record]
      verdict.green? ? 0 : 1
    rescue GateRun::Refused => e
      warn e.message
      2
    end

    # exit code 2 when the manifest is not this chain's open gating attempt
    def gate_refusal(manifest, chain)
      if manifest.chain != chain.name
        warn "manifest belongs to chain #{manifest.chain}, not #{chain.name}"
        return 2
      end
      return if manifest.state == "gating" && manifest.current_attempt

      warn "manifest is not in the gating state (state: #{manifest.state})"
      2
    end

    def run_gate(chain, graph, manifest, options)
      findings = options[:externals] ? external_findings(chain, graph) : []
      GateRun.new(chain: chain, graph: graph, workdir: options[:workdir],
                  shell: @shell, token: github_token)
        .call(manifest.current_attempt.pins, externals: findings)
    end

    # an empty variable is no token: it would send a blank auth header
    def github_token
      [ENV.fetch("GITHUB_TOKEN", nil), ENV.fetch("GH_TOKEN", nil)]
        .find { |token| !token.to_s.empty? }
    end

    def record_verdict(manifest, verdict, path)
      manifest.record_gate!(verdict.result, verdict.suspects)
      manifest.write(path)
    end

    def render_verdict(verdict, index)
      puts "gate attempt #{index}: #{verdict.result.upcase}"
      verdict.steps.each do |s|
        puts "  [#{s.status}] #{s.name}"
        puts s.detail.gsub(/^/, "      ") unless s.status == "ok" || s.detail.empty?
      end
      return if verdict.suspects.empty?

      puts "  suspects (gems gated by failing corpora): #{verdict.suspects.join(', ')}"
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
        payload = action_payload(action)
        if action.is_a?(Machine::Gate)
          payload[:corpora] = corpora_payload(chain.corpora_for(
                                                manifest.current_attempt.pins.keys,
                                              ))
        end
        puts JSON.generate(payload.merge(state: manifest.state))
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

    def corpora_payload(entries)
      entries.map do |e|
        { repo: e.repo, ref: e.ref, documents: e.documents, budget: e.budget,
          gems: e.gems }
      end
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
      recipe.corpora.each do |c|
        docs = c.documents.empty? ? "all" : c.documents.join(", ")
        puts "  corpus #{c.repo}@#{c.ref} (gems: #{c.gems.join(', ')}; " \
             "docs: #{docs}; budget #{c.budget}s)"
      end
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

    def policy
      options = { next_version: nil }
      OptionParser.new do |o|
        o.on("--next-version V") { |v| options[:next_version] = v }
      end.parse!(@argv)
      root = @argv.shift
      return usage unless root

      findings = Policy.new(File.expand_path(root),
                            next_version: options[:next_version]).check
      findings.each { |f| puts "#{f.rule}: #{f.message}" }
      puts "policy: #{findings.empty? ? 'ok' : "#{findings.size} violation(s)"}"
      findings.empty? ? 0 : 1
    end

    def notes
      options = {}
      OptionParser.new do |o|
        o.on("--prs PATH") { |v| options[:prs] = v }
        o.on("--version V") { |v| options[:version] = v }
      end.parse!(@argv)
      return usage unless options[:prs] && options[:version]

      puts ReleaseNotes.new(JSON.parse(File.read(options[:prs]))).render(options[:version])
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
        o.on("--tags") { |v| options[:tags] = v }
        o.on("--issue OWNER/REPO") { |v| options[:issue] = v }
        o.on("--semantic") { |v| options[:semantic] = v }
        o.on("--root PATH") { |v| options[:root] = v }
        o.on("--apply") { |v| options[:apply] = v }
        o.on("--workdir PATH") { |v| options[:workdir] = v }
        o.on("--record") { |v| options[:record] = v }
      end.parse!(@argv)
    end

    def load_chain(options)
      return nil unless options[:chain]

      Chain.load(options[:chain])
    end

    def usage
      warn "usage: ancora plan --network PATH [--delta PATH] [--chain chain.yml] [--seeds a,b] [--semantic]"
      warn "       ancora pin --chain chain.yml --network PATH [--delta PATH]"
      warn "       ancora drift --network PATH [--delta PATH] [--chain chain.yml]"
      warn "       ancora drift-report --network PATH --delta PATH [--chain chain.yml] [--tags] [--issue OWNER/REPO]"
      warn "       ancora externals --chain chain.yml --network PATH [--delta PATH]"
      warn "       ancora check GEM VERSION"
      warn "       ancora tag OWNER/REPO VERSION"
      warn "       ancora ci OWNER/REPO [BRANCH]"
      warn "       ancora step --chain chain.yml --network PATH --delta PATH [--manifest PATH]"
      warn "       ancora approve --manifest PATH"
      warn "       ancora policy GEM_CHECKOUT [--next-version X.Y.Z]"
      warn "       ancora notes --prs PRS.json --version X.Y.Z"
      warn "       ancora floors --network PATH [--delta PATH] [--chain chain.yml] [--root CHECKOUTS --apply]"
      warn "       ancora gate --chain chain.yml --network PATH [--delta PATH] --manifest PATH [--workdir DIR] [--externals] [--record]"
      1
    end
  end
end
