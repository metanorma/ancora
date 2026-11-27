# frozen_string_literal: true

require "cgi"
require "date"
require "fileutils"
require "json"
require "net/http"
require "open3"
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
  autoload :DriftReport, "ancora/drift_report"
  autoload :Externals, "ancora/externals"
  autoload :FleetDrift, "ancora/fleet_drift"
  autoload :GateLock, "ancora/gate_lock"
  autoload :GateRecipe, "ancora/gate_recipe"
  autoload :IssueSink, "ancora/issue_sink"
  autoload :FloorFixer, "ancora/floor_fixer"
  autoload :FloorApplier, "ancora/floor_applier"
  autoload :GemspecEdit, "ancora/gemspec_edit"
  autoload :GateRun, "ancora/gate_run"
  autoload :Shell, "ancora/shell"
  autoload :Machine, "ancora/machine"
  autoload :Manifest, "ancora/manifest"
  autoload :Policy, "ancora/policy"
  autoload :ReleaseNotes, "ancora/release_notes"
  autoload :CLI, "ancora/cli"
end
