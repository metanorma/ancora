# frozen_string_literal: true

require "cgi"
require "json"
require "net/http"
require "rubygems"
require "uri"
require "yaml"

# Ancora (Latin: anchor) orchestrates dependency-ordered release waves for
# gem fleets. One invariant governs everything: rubygems, CI runs, and git
# tags are the only truth; every piece of ancora state is a cache over
# those oracles, so a crash at any point resumes by re-querying them.
module Ancora
  autoload :Version, "ancora/version"
  autoload :Graph, "ancora/graph"
  autoload :Chain, "ancora/chain"
  autoload :Planner, "ancora/planner"
  autoload :Oracle, "ancora/oracle"
  autoload :Candidate, "ancora/candidate"
  autoload :Drift, "ancora/drift"
  autoload :GateLock, "ancora/gate_lock"
  autoload :Manifest, "ancora/manifest"
  autoload :CLI, "ancora/cli"
end
