# frozen_string_literal: true

require "shellwords"

module Ancora
  # Runs a gate recipe: the GateLock full-set compile, gem suites and canary
  # corpus gate. It never publishes; every subprocess goes through the
  # injected shell, so specs and dry runs stay offline.
  #
  #   1. lock    - write the Gemfile pinning the ENTIRE candidate set
  #   2. compile - `bundle lock` then `bundle install` against that lock:
  #                conflicting floors or a missing candidate fail here
  #   3. suites  - chain.yml gate commands in each gem's main checkout,
  #                bundled from the gem's own Gemfile with the candidate
  #                set forced on top (GateLock#suite_gemfile)
  #   4. canary  - chain.yml canary commands, run once per configured
  #                corpus checkout (documents in ANCORA_CORPUS_DOCUMENTS,
  #                the corpus budget as the timeout), or once in the lock
  #                directory when the chain configures no corpus
  #
  # The verdict is green only when every step passed. A failed compile
  # skips suites and canary; a failed suite skips canary and names its gem
  # as suspect. A red corpus names the gems it gates, as the
  # suspects of the next attempt. The engine enforces only the configured
  # corpora; it never infers coverage.
  class GateRun
    Step = Struct.new(:name, :kind, :status, :detail, :gems,
                      keyword_init: true)
    Verdict = Struct.new(:result, :steps, :suspects, keyword_init: true) do
      def green?
        result == "green"
      end
    end

    class Refused < StandardError; end

    # a suite or canary command that would publish is a config error, never run
    PUBLISHING = Regexp.union(
      /\bgem\b.*\bpush\b/, /rubygems-release/,
      /\bgh\b.*\b(?:release|workflow)\b/, /\bgit\b.*\b(?:push|tag)\b/,
      /\brake\b.*\brelease\b/
    )

    # commands never see publishing credentials; RUBYOPT from an outer
    # `bundle exec` would inject a backtrace into bundler's own failure output
    SCRUBBED_ENV = %w[GEM_HOST_API_KEY RUBYGEMS_API_KEY GITHUB_TOKEN GH_TOKEN
                      RUBYOPT]
      .to_h { |name| [name, nil] }.freeze

    DETAIL_LINES = 12
    DETAIL_MARKER = /Could not find|Gem::|Error/
    SUITE_GEMFILE = "Gemfile.ancora"

    def initialize(chain:, graph:, workdir:, shell: Shell.new, token: nil,
                   clone_url: nil)
      @chain = chain
      @graph = graph
      @workdir = File.expand_path(workdir)
      @shell = shell
      @token = token
      @clone_url = clone_url || ->(repo) { "https://github.com/#{repo}.git" }
    end

    def call(pins, externals: [])
      validate_pins!(pins)
      recipe = GateRecipe.new(@chain, @graph).build(pins)
      validate_commands!(recipe)
      blocked = awaiting_step(externals)
      return verdict([blocked]) if blocked

      steps = compile(pins, externals)
      steps.concat(suites(recipe, pins, externals)) if all_ok?(steps)
      steps.concat(canary(recipe)) if all_ok?(steps)
      verdict(steps)
    end

    private

    def all_ok?(steps)
      steps.all? { |s| s.status == "ok" }
    end

    # a suite needs its repo to clone; a pin the graph cannot place has none
    def validate_pins!(pins)
      unknown = pins.keys.reject { |gem| @graph.nodes.key?(gem) }
      return if unknown.empty?

      raise Refused, "pinned gem(s) not in the graph: #{unknown.join(', ')}"
    end

    def validate_commands!(recipe)
      refuse_publishing!(recipe.canary, "canary")
      recipe.suites.each { |suite| refuse_publishing!(suite.commands, "suite") }
    end

    def refuse_publishing!(commands, kind)
      bad = commands.select { |command| publishing?(command) }
      return if bad.empty?

      raise Refused, "#{kind} command would publish: #{bad.join('; ')}"
    end

    # matched on the words the shell runs, so quoting cannot hide a verb
    def publishing?(command)
      PUBLISHING.match?(Shellwords.split(command).join(" "))
    rescue ArgumentError
      raise Refused, "command cannot be read: #{command}"
    end

    # the lock cannot be completed while an external need has no final:
    # red without running anything (the gate never validates a prerelease
    # of another chain)
    def awaiting_step(externals)
      awaiting = GateLock.new(@chain, @graph, externals: externals).awaiting
      return if awaiting.empty?

      list = awaiting.map { |f| "#{f.from.join(', ')} -> #{f.gem}" }
      Step.new(name: "lock: externals awaiting release", kind: "compile",
               status: "failed", detail: list.join("\n"), gems: [])
    end

    def compile(pins, externals)
      reset_gem_home
      FileUtils.mkdir_p(lock_dir)
      lock = GateLock.new(@chain, @graph, externals: externals)
      File.write(File.join(lock_dir, "Gemfile"), lock.gemfile(pins))
      steps = []
      [%w[bundle lock], %w[bundle install]].each do |argv|
        steps << run_step(argv, "lock: #{argv.join(' ')}", "compile")
        break unless steps.last.status == "ok"
      end
      steps
    end

    def run_step(argv, name, kind)
      step(name, kind, @shell.run(argv, chdir: lock_dir, env: bundle_env))
    end

    def suites(recipe, pins, externals)
      lock = GateLock.new(@chain, @graph, externals: externals)
      recipe.suites.flat_map { |suite| gem_suite(suite, lock, pins) }
    end

    # the suite's own Gemfile keeps its test dependencies in the bundle;
    # the overlay forces the candidate set onto it (see GateLock)
    def gem_suite(suite, lock, pins)
      dir = File.join(@workdir, "suites", suite.gem)
      cloned = clone(suite.repo, dir, ref: "main", kind: "suite",
                                      gems: [suite.gem])
      return [cloned] unless cloned.status == "ok"

      env = write_overlay(dir, lock.suite_gemfile(pins, own: suite.gem))
      run_suite(suite, dir, env)
    end

    def run_suite(suite, dir, env)
      installed = suite_step(suite, dir, env, %w[bundle install])
      return [installed] unless installed.status == "ok"

      [installed] + suite.commands.map { |c| suite_step(suite, dir, env, c) }
    end

    def write_overlay(dir, gemfile)
      env = suite_env(dir)
      FileUtils.mkdir_p(dir)
      File.write(env["BUNDLE_GEMFILE"], gemfile)
      env
    end

    def suite_step(suite, dir, env, command)
      result = @shell.run(command, chdir: dir, env: env)
      label = command.is_a?(Array) ? command.join(" ") : command
      step("suite #{suite.gem}: #{label}", "suite", result, gems: [suite.gem])
    end

    def canary(recipe)
      return lock_dir_canary(recipe) if recipe.corpora.empty?

      recipe.corpora.flat_map { |corpus| corpus_canary(corpus, recipe.canary) }
    end

    def lock_dir_canary(recipe)
      recipe.canary.map do |command|
        result = @shell.run(command, chdir: lock_dir, env: bundle_env)
        step("canary: #{command}", "canary", result, gems: [])
      end
    end

    def corpus_canary(corpus, commands)
      dir = File.join(@workdir, "corpora", corpus.repo.gsub("/", "__"))
      cloned = clone(corpus.repo, dir, ref: corpus.ref, kind: "corpus",
                                       gems: corpus.gems)
      return [cloned] unless cloned.status == "ok"

      commands.map { |command| corpus_step(corpus, dir, command) }
    end

    def corpus_step(corpus, dir, command)
      env = bundle_env.merge(
        "ANCORA_CORPUS_DOCUMENTS" => corpus.documents.join("\n"),
      )
      result = @shell.run(command, chdir: dir, env: env, timeout: corpus.budget)
      step("corpus #{corpus.repo}: #{command}", "corpus", result,
           gems: corpus.gems)
    end

    def clone(repo, dir, ref:, kind:, gems:)
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(File.dirname(dir))
      argv = ["git", "clone", "--depth", "1", "--branch", ref,
              @clone_url.call(repo), dir]
      result = @shell.run(argv, chdir: @workdir, env: git_env)
      step("clone #{repo}@#{ref}", kind, result, gems: gems)
    end

    def verdict(steps)
      failed = steps.reject { |s| s.status == "ok" }
      suspects = failed.flat_map(&:gems).uniq.sort
      Verdict.new(result: failed.empty? ? "green" : "red", steps: steps,
                  suspects: suspects)
    end

    def step(name, kind, result, gems: [])
      status = if result.ok? then "ok"
               elsif result.timed_out then "timeout"
               else "failed"
               end
      Step.new(name: name, kind: kind, status: status,
               detail: detail(result.output), gems: gems)
    end

    # the cause line of a failure is often not in the last lines, so the
    # first marked lines are kept beside the tail
    def detail(output)
      lines = output.to_s.lines
      kept = (marked_indexes(lines) | tail_indexes(lines)).sort
      redact(kept.map { |i| lines[i] }.join)
    end

    # bundler states its cause after the resolver's noise, so the last
    # marked lines are kept beside the first ones
    def marked_indexes(lines)
      marked = lines.each_index.select { |i| DETAIL_MARKER.match?(lines[i]) }
      marked.first(DETAIL_LINES) | marked.last(DETAIL_LINES)
    end

    def tail_indexes(lines)
      ([lines.size - DETAIL_LINES, 0].max...lines.size).to_a
    end

    def redact(text)
      @token ? text.gsub(@token, "***") : text
    end

    def lock_dir
      File.join(@workdir, "lock")
    end

    def bundle_env
      gate_env.merge("BUNDLE_GEMFILE" => File.join(lock_dir, "Gemfile"))
    end

    def suite_env(dir)
      gate_env.merge("BUNDLE_GEMFILE" => File.join(dir, SUITE_GEMFILE))
    end

    # a fresh home per gate run: installs never reuse gems from an earlier
    # attempt or from the caller's machine
    def gate_env
      SCRUBBED_ENV.merge("GEM_HOME" => gem_home, "GEM_PATH" => gem_home)
    end

    def gem_home
      File.join(@workdir, "gem_home")
    end

    def reset_gem_home
      FileUtils.rm_rf(gem_home)
    end

    # the token travels in the environment, never in argv or the URL
    def git_env
      return SCRUBBED_ENV unless @token

      basic = ["x-access-token:#{@token}"].pack("m0")
      SCRUBBED_ENV.merge(
        "GIT_CONFIG_COUNT" => "1",
        "GIT_CONFIG_KEY_0" => "http.https://github.com/.extraheader",
        "GIT_CONFIG_VALUE_0" => "Authorization: basic #{basic}",
      )
    end
  end
end
