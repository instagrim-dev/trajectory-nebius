# Trajectory queued-export fixture

Local test fixture for the Trajectory workbench. The judge import target is the
[public synthetic service](https://github.com/instagrim-dev/trajectory-nebius-demo).
Both model-generated choices are retained as separate candidate workspaces; the
recorded source and check summary are in this repository's `evidence/` folder.

- `queued/` — service source plus the coordinator-owned independent oracle
  (`queued_test.go`; candidates must not edit tests to pass).
- `cmd/exportdemo` — runnable request → revoke → process scenario.
- `.trajectory/intent.json` — coordinator-owned accepted-intent manifest.
- `go.mod` — pinned module identity used by the local checker.

Baseline policy: `delivery_time`. Candidate A revises to `queue_time`;
candidate B-2 revises saved A back to `delivery_time` as a descendant candidate.
The recorded candidates were not committed to the baseline repository.
Synthetic data only; no external systems.
