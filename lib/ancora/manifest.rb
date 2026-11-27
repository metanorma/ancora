# frozen_string_literal: true

module Ancora
  # The wave state manifest: a cache over the oracles, committed to the
  # chain repo between steps. An attempt is an immutable pinned set
  # {gem => version} with its planned waves; a gate verdict is recorded
  # against it, and promotion migrates the first fully-green attempt.
  # Rebuildable from the oracles at any time.
  class Manifest
    Attempt = Struct.new(:index, :pins, :created_at, :waves, :gate_result,
                         :changed, keyword_init: true)

    class Invalid < StandardError; end

    NEEDS_ATTEMPT = %w[candidate gating promoted].freeze

    attr_reader :chain, :state, :attempts, :wave_cursor, :promote_cursor

    def self.load(path, fallback_chain = nil)
      data = File.file?(path) ? parse(path) : {}
      manifest = new(data.fetch("chain", fallback_chain ||
                     File.basename(File.dirname(path))),
                     data.fetch("state", "planned"), data.fetch("attempts", []),
                     data.fetch("wave_cursor", 0), data.fetch("promote_cursor", 0),
                     data.fetch("approved", false))
      problem = problem_in(manifest)
      raise Invalid, "#{path}: #{problem}" if problem

      manifest
    end

    def self.parse(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      raise Invalid, "#{path}: not JSON (#{e.message.lines.first.strip})"
    end

    # a hand-edited file fails here in one line, not deep inside a step;
    # a final pin has no target to renumber from, so it must never dispatch
    def self.problem_in(manifest)
      if NEEDS_ATTEMPT.include?(manifest.state) && manifest.attempts.empty?
        return "no attempt to act on"
      end

      manifest.attempts.lazy.filter_map { |a| attempt_problem(a) }.first ||
        cursor_problem(manifest)
    end

    def self.attempt_problem(attempt)
      pin_problem(attempt) || changed_problem(attempt)
    end

    def self.pin_problem(attempt)
      final = attempt.pins.values.find { |v| !Candidate.candidate?(v) }
      "attempt #{attempt.index}: pin #{final} is not a candidate version" if final
    end

    def self.changed_problem(attempt)
      return "attempt #{attempt.index}: changed must be a list" unless attempt.changed.is_a?(Array)

      stray = attempt.changed - attempt.pins.keys
      "attempt #{attempt.index}: changed #{stray.join(', ')} not among the pinned gems" unless stray.empty?
    end

    def self.cursor_problem(manifest)
      case manifest.state
      when "candidate"
        waves = manifest.current_attempt.waves.size
        "wave cursor #{manifest.wave_cursor} is past the attempt's waves" if manifest.wave_cursor > waves
      when "promoted"
        return "no green attempt to promote" unless manifest.promoted_from

        waves = manifest.promoted_from.waves.size
        "promote cursor #{manifest.promote_cursor} is past the promoted waves" if manifest.promote_cursor > waves
      end
    end

    private_class_method :parse, :problem_in, :attempt_problem, :pin_problem,
                         :changed_problem, :cursor_problem

    def initialize(chain, state = "planned", attempts = [], wave_cursor = 0,
                   promote_cursor = 0, approved = false)
      @chain = chain
      @state = state
      @wave_cursor = wave_cursor
      @promote_cursor = promote_cursor
      @approved = approved
      @attempts = attempts.map do |a|
        Attempt.new(index: a["index"], pins: a["pins"],
                    created_at: a["created_at"],
                    waves: a.fetch("waves", []),
                    gate_result: a["gate_result"],
                    changed: a.fetch("changed", []))
      end
    end

    def approved?
      @approved
    end

    def approve!
      @approved = true
      self
    end

    def open_attempt(pins, waves = [])
      @attempts << Attempt.new(index: @attempts.size + 1, pins: pins,
                               created_at: now, waves: waves,
                               gate_result: nil, changed: [])
      @wave_cursor = 0
      @state = "candidate"
      self
    end

    def current_attempt
      @attempts.last
    end

    def gate!
      raise "no open attempt" unless current_attempt

      @state = "gating"
      self
    end

    def record_gate!(result, changed = [])
      raise "no open attempt" unless current_attempt

      current_attempt.gate_result = result
      current_attempt.changed = changed
      self
    end

    def advance_wave
      @wave_cursor += 1
      self
    end

    def start_promotion(attempt)
      raise "attempt #{attempt.index} is not green" unless attempt.gate_result == "green"

      @state = "promoted"
      @promote_cursor = 0
      self
    end

    # promotion always migrates the first fully-green attempt
    def promoted_from
      attempts.find { |a| a.gate_result == "green" }
    end

    def advance_promote
      @promote_cursor += 1
      self
    end

    def finish!
      @state = "done"
      self
    end

    def write(path)
      FileUtils.mkdir_p(File.dirname(path))
      json = JSON.pretty_generate(
        chain: @chain, state: @state,
        wave_cursor: @wave_cursor, promote_cursor: @promote_cursor,
        approved: @approved,
        attempts: @attempts.map do |a|
          { index: a.index, pins: a.pins, created_at: a.created_at,
            waves: a.waves, gate_result: a.gate_result, changed: a.changed }
        end
      )
      File.write(path, "#{json}\n")
    end

    private

    def now
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end
  end
end
