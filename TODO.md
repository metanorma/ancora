# ancora — TODOs for the next agent

`ancora` (Latin: *anchor*) is the dependency-ordered release-wave orchestrator for the
gem fleets: metanorma, lutaml, relaton, glossarist. This repo holds the ENGINE GEM.
The design of record is `~/src/mn/gemspec-audit/ORCHESTRATOR-PLAN.md` (v2) with
`RELEASE-ORCHESTRATOR-AUDIT.md` (feasibility + failure modes F1-F9) — READ BOTH FIRST.

## The one invariant

rubygems, CI runs, and git tags are the only truth. Every piece of ancora state is a
cache over those oracles. A crash at any point resumes by re-querying them; nothing
ever double-publishes (the release workflows' idempotent push guards are probe-verified).

## Wave lifecycle (implemented shape)

planned -> candidate -> gating -> promoted -> done, with ATTEMPTS: a failed gate
spawns candidate attempt K+1 (per-gem alpha counters increment only for gems whose
main changed since attempt K); attempts are immutable pinned sets; promotion only
from the first fully-green attempt. Candidates are X.Y.Z.pre.alpha.N — invisible to
default resolvers. Promotion = finals in wave order, floors to finals (never alphas),
terminus (metanorma-cli) last, wave manifest embedded in its release notes.

## What exists in this repo (M1 skeleton — keep it working)

- `lib/ancora/graph.rb` — fleet graph from network.json/delta.json (nodes, edges,
  dependents/dependencies, floorless-edge detection)
- `lib/ancora/planner.rb` — wave planning: full scope (release drift) and scoped
  (repair waves from seeds), Kahn antichains, leaves first
- `lib/ancora/oracle.rb` — read-only rubygems versions API client (published?,
  latest, next_candidate_index)
- `lib/ancora/candidate.rb` — prerelease numbering, per-(gem, semver-target) counters
- `lib/ancora/manifest.rb` — wave state as a cache (attempts = pinned sets)
- `lib/ancora/cli.rb` + `exe/ancora` — dry-run: `ancora plan --network ... --delta ...`,
  `ancora plan --seeds gem1,gem2`, `ancora check GEM VERSION`
- specs use REAL graph fixtures (a fleet slice) — never doubles; run: `bundle exec rspec`

Test the CLI against the live collector data:
  bundle exec exe/ancora plan --network ~/src/mn/gemspec-audit/network.json --delta ~/src/mn/gemspec-audit/delta.json

## M1 remaining (finish before anything else)

- [ ] CI workflow (rake matrix like the org's gems; rubocop to house style)
- [ ] `ancora drift` subcommand: floorless edges + stale pins + unreleased main as a
      report (this becomes cimas-drift-audit class (h) later)
- [ ] Graph monorepo modeling: repo -> gem-set units (relaton ships relaton +
      relaton-cli; pubid ships many) — waves version the repo, floors expand to the set
- [ ] Planner terminus assertion: the configured terminus (e.g. metanorma-cli) must be
      alone in the final wave; error otherwise
- [ ] Oracle: GitHub CI-run oracle + git-tag oracle (read-only; `gh run` JSON)

## M2 — GHA runtime wiring

- [ ] `metanorma/release` repo: `chain.yml` config (inventory, roots/terminus,
      candidate set, soak window, promote approval, gate commands, ruby matrix,
      external chains with needs) + the `release-wave` workflow (inputs: wave, dry_run)
- [ ] Step-per-run state machine: one workflow run performs ONE transition (dispatch,
      poll, gate step, promote step), commits the manifest, exits; next step continues
      via workflow_dispatch/schedule — waves exceed the 6h single-run limit
- [ ] Manifest repo as the lock: push conflicts -> rebase and retry; duplicate
      dispatches are safe (push guard no-ops, probe-verified 2026-10-05)
- [ ] Secrets: the orchestrator dispatches each gem's OWN rubygems-release.yml
      (that repo's secrets publish); ancora needs only a PAT with workflow scope

## M3 — candidate loop + integration gate + canary

- [ ] Candidate dispatch: on green main, dispatch next_version=X.Y.Z.pre.alpha.N via
      the gem repo's release workflow; poll the rubygems oracle until visible
- [ ] Gate-lock generator: emit a Gemfile pinning the ENTIRE candidate set (bundler
      never resolves prereleases implicitly — exact pins, multi-level candidates
      included); `bundle lock`; run each next-wave gem's suite in a disposable container
- [ ] CANARY STAGE (mandatory — the campaign's core lesson): compile a small REAL
      corpus document end-to-end INCLUDING presentation/site rendering against the
      pinned candidate set. Unit-green does not mean works: cg3 passed its whole
      semantic-XML pipeline and failed only at site-gen citation rendering
      (Relaton::Render::I18n) on 2026-10-05.
- [ ] Attempt loop: red gate -> fix on main -> alpha.N+1 only for changed gems ->
      re-gate; max_attempts (default 3) then halt for humans with the attempt history

## M4 — first supervised full wave (metanorma chain)

- [ ] Promote step: finals in wave order (idempotent dispatches), floors raised to
      finals, dependents re-locked, terminus last + wave manifest in release notes
- [ ] Guardrail: promote approval = manual until two supervised waves complete clean

## M5 — external chains + handshakes

- [ ] lutaml/release, relaton/release, glossarist/release with the same engine +
      their chain.yml
- [ ] Candidate mirroring: candidate-gates may pin an external chain's latest GREEN
      candidate; promote-gates require the external chain's FINALS
- [ ] Release-request handshake: when metanorma needs an unreleased external API
      (the ea 0.6.41 case), file a release request on the external chain repo and
      gate on its rubygems oracle

## Lint rules the engine enforces

- No gemspec floor may ever reference a prerelease version
- Every dependency edge in the chain config must carry a floor (floorless = the
  hidden-coupling class that shipped metanorma-plugin-lutaml against an ea release
  lacking Ea::Xmi.load_graph — fixed 2026-10-05 with ea >= 0.6.41)

## House rules (absolute)

- Never push tags, never commit/push/merge to main; PRs rebase-merge; stage by
  explicit path (never `git add -A`); no AI-attribution trailers; no filing outside
  metanorma/lutaml/relaton/pubid/ribose orgs; ask before destructive actions.
- Code: autoload in the parent namespace file (no require_relative in lib);
  no hand-rolled to_h/from_h on models — typed Structs + JSON at the edges;
  specs use real objects, never doubles.
- Version numbers are the owner's decision — the gem's own releases included.

## Background pointers

- Audit + plans: `~/src/mn/gemspec-audit/` (network.json, delta.json, LOCKCHAIN.md,
  REPORT.md, ORCHESTRATOR-PLAN.md, RELEASE-ORCHESTRATOR-AUDIT.md — the collector
  scripts live there too)
- Release mechanism: `rubygems-release.yml` (workflow_dispatch, next_version;
  idempotent push guard; advisory ci#369 proposes bump levels)
- Drift machinery to integrate with: metanorma/ci `.github/scripts/cimas-drift-audit.rb`
