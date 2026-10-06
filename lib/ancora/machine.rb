# frozen_string_literal: true

module Ancora
  # The step-per-run wave state machine: one invocation performs ONE
  # transition over the manifest and returns the action for the runtime
  # to execute (a workflow run dispatches, polls, gates, or promotes one
  # step, commits the manifest, exits; the next run continues - waves
  # exceed any single-run time limit). Pure decision logic: actions are
  # data, oracles are injected, and nothing here dispatches, releases,
  # or invents versions - candidate targets come from the owner's data
  # (the gemspec on main, or an advisory the owner approved).
  class Machine
    class Error < StandardError; end

    Item = Struct.new(:gem, :repo, :version, keyword_init: true)
    DispatchWave = Struct.new(:index, :items, keyword_init: true)
    Gate = Struct.new(:attempt_index, keyword_init: true)
    PromoteWave = Struct.new(:index, :items, keyword_init: true)
    Halt = Struct.new(:reason, keyword_init: true)
    Hold = Struct.new(:reason, keyword_init: true)
    Done = Struct.new(:state, keyword_init: true)

    DEFAULT_MAX_ATTEMPTS = 3

    def initialize(chain:, graph:, oracle:)
      @chain = chain
      @graph = graph
      @oracle = oracle
    end

    def step(manifest, targets = {})
      @targets = targets
      case manifest.state
      when "planned" then open_first_attempt(manifest)
      when "candidate" then candidate_step(manifest)
      when "gating" then gating_step(manifest)
      when "promoted" then promoted_step(manifest)
      when "done" then Done.new(state: "done")
      else raise Error, "unknown manifest state #{manifest.state}"
      end
    end

    private

    def open_first_attempt(manifest)
      waves = Planner.new(@graph, chain: @chain).plan
      pins = waves.flatten.to_h do |gem|
        [gem,
         Candidate.version(target(gem),
                           @oracle.next_candidate_index(gem, target(gem)))]
      end
      manifest.open_attempt(pins, waves)
      dispatch_wave(manifest, 0)
    end

    def candidate_step(manifest)
      attempt = manifest.current_attempt
      wave = attempt.waves[manifest.wave_cursor]
      wave_published = wave.all? do |gem|
        @oracle.published?(gem, attempt.pins[gem])
      end
      return dispatch_wave(manifest, manifest.wave_cursor) unless wave_published

      if manifest.wave_cursor < attempt.waves.size - 1
        manifest.advance_wave
        return dispatch_wave(manifest, manifest.wave_cursor)
      end

      manifest.gate!
      Gate.new(attempt_index: attempt.index)
    end

    def gating_step(manifest)
      if (green = manifest.promoted_from)
        return hold_for_approval(green) if approval_required?(manifest)

        manifest.start_promotion(green)
        return promote_wave(manifest, 0)
      end

      return Halt.new(reason: halt_reason(manifest)) if exhausted?(manifest)
      return Gate.new(attempt_index: manifest.current_attempt.index) unless manifest.current_attempt.gate_result == "red"

      reopen_changed(manifest)
    end

    # the guardrail: no finals without explicit approval
    def approval_required?(manifest)
      @chain.promote_approval == "manual" && !manifest.approved?
    end

    def hold_for_approval(attempt)
      Hold.new(reason: "attempt #{attempt.index} is green; awaiting promote " \
                       "approval (ancora approve --manifest ...)")
    end

    def promoted_step(manifest)
      attempt = manifest.promoted_from
      cursor = manifest.promote_cursor
      wave = attempt.waves[cursor]
      unless wave.all? { |gem| @oracle.published?(gem, final(attempt, gem)) }
        return promote_wave(manifest, cursor)
      end

      if cursor == attempt.waves.size - 1
        manifest.finish!
        return Done.new(state: "done")
      end

      manifest.advance_promote
      promote_wave(manifest, manifest.promote_cursor)
    end

    # a failed gate spawns attempt K+1: fresh alpha counters only for
    # the gems whose main changed since attempt K; the rest keep their
    # immutable attempt-K pins
    def reopen_changed(manifest)
      previous = manifest.current_attempt
      pins = previous.pins.merge(previous.changed.to_h do |gem|
        [gem, fresh_candidate(gem, previous)]
      end)
      manifest.open_attempt(pins, previous.waves)
      dispatch_wave(manifest, 0)
    end

    def dispatch_wave(manifest, index)
      attempt = manifest.current_attempt
      wave = attempt.waves[index]
      items = wave.map do |gem|
        Item.new(gem: gem, repo: @graph.nodes[gem]&.repo,
                 version: attempt.pins[gem])
      end
      DispatchWave.new(index: index, items: items)
    end

    def promote_wave(manifest, index)
      attempt = manifest.promoted_from
      items = attempt.waves[index].map do |gem|
        Item.new(gem: gem, repo: @graph.nodes[gem]&.repo,
                 version: final(attempt, gem))
      end
      PromoteWave.new(index: index, items: items)
    end

    def fresh_candidate(gem, previous)
      target = @targets[gem] || Candidate.target_of(previous.pins[gem])
      Candidate.version(target, @oracle.next_candidate_index(gem, target))
    end

    def target(gem)
      @targets[gem] || @graph.nodes[gem]&.main_version ||
        raise(Error, "no owner-decided target version for #{gem}")
    end

    def final(attempt, gem)
      Candidate.target_of(attempt.pins[gem])
    end

    def exhausted?(manifest)
      manifest.attempts.size >= max_attempts
    end

    def halt_reason(manifest)
      "halted after #{manifest.attempts.size} attempts " \
        "(max #{@chain.max_attempts}); attempt history kept for humans"
    end

    def max_attempts
      @chain.max_attempts || DEFAULT_MAX_ATTEMPTS
    end
  end
end
