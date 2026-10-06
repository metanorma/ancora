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

    attr_reader :chain, :state, :attempts, :wave_cursor, :promote_cursor

    def self.load(path, fallback_chain = nil)
      data = File.file?(path) ? JSON.parse(File.read(path)) : {}
      new(data.fetch("chain", fallback_chain ||
                     File.basename(File.dirname(path))),
          data.fetch("state", "planned"), data.fetch("attempts", []),
          data.fetch("wave_cursor", 0), data.fetch("promote_cursor", 0),
          data.fetch("approved", false))
    end

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
      require "fileutils"
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
