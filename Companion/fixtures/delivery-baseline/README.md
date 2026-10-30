# trajectory-live-demo (private)

Dedicated demo target for the Trajectory live GitHub workbench: a small
synthetic queued-export service where the governing authorization policy
(queue-time snapshot vs delivery-time re-check) is an explicit, revisable
decision.

- `queued/` — service source plus the coordinator-owned independent oracle
  (`queued_test.go`; candidates must not edit tests to pass).
- `cmd/exportdemo` — runnable request → revoke → process scenario.
- `.trajectory/intent.json` — coordinator-owned accepted-intent manifest.
- `.github/workflows/ci.yml` — push-triggered build, vet, test, scenario.

Baseline policy: `delivery_time`. Candidate A revises to `queue_time`;
candidate B revises A back to `delivery_time` as a real descendant commit.
Synthetic data only; no external systems.
