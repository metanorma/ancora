# frozen_string_literal: true

module Ancora
  # Candidate (prerelease) numbering: X.Y.Z.pre.alpha.N, one counter per
  # (gem, semver target). A mid-wave change of the semver target restarts
  # the counter under the new target; counters never mix targets.
  class Candidate
    PREFIX = ".pre.alpha."

    def self.version(target, index)
      "#{target}#{PREFIX}#{index + 1}"
    end

    def self.target_of(version)
      version[/\A(.+)#{Regexp.escape(PREFIX)}\d+\z/, 1]
    end

    def self.candidate?(version)
      !target_of(version).nil?
    end
  end
end
