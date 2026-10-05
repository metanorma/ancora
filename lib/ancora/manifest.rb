# frozen_string_literal: true

module Ancora
  # The wave state manifest: a cache over the oracles, committed to the
  # chain repo between steps. An attempt is an immutable pinned set
  # {gem => version}; promotion only ever migrates a fully-green
  # attempt. Rebuildable from the oracles at any time.
  class Manifest
    Attempt = Struct.new(:index, :pins, :created_at, keyword_init: true)

    attr_reader :chain, :state, :attempts

    def self.load(path)
      data = File.file?(path) ? JSON.parse(File.read(path)) : {}
      new(data.fetch("chain", File.basename(File.dirname(path))),
          data.fetch("state", "planned"), data.fetch("attempts", []))
    end

    def initialize(chain, state = "planned", attempts = [])
      @chain = chain
      @state = state
      @attempts = attempts.map do |a|
        Attempt.new(index: a["index"], pins: a["pins"], created_at: a["created_at"])
      end
    end

    def open_attempt(pins)
      @attempts << Attempt.new(index: @attempts.size + 1, pins: pins,
                               created_at: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"))
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

    def write(path)
      require "fileutils"
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(
        chain: @chain, state: @state,
        attempts: @attempts.map do |a|
          { index: a.index, pins: a.pins, created_at: a.created_at }
        end
      ) + "\n")
    end
  end
end
