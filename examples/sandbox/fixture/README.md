# Sandbox collector fixture (FIXTURE, NOT REAL DATA)

The metanorma-sandbox org has no gem mirrors yet, so there is no collector
snapshot to plan against. These two files are a hand-written stand-in with
the collector's shape, used only by the dry-run spec in
`spec/sandbox_rehearsal_spec.rb`. Do not treat plans over them as evidence
about the real fleet.

    ancora plan --network examples/sandbox/fixture/network.json \
                --delta examples/sandbox/fixture/delta.json \
                --chain examples/sandbox.chain.yml
