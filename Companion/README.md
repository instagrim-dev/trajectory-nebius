# Native companion

The Nebius submission runs NVIDIA Nemotron 3.5 Lightning through Token Factory. From the project root, supply a key to the Mac host environment and start the loopback companion:

```sh
export NEBIUS_API_KEY=...   # supply privately in your shell
TRAJECTORY_GENERATOR_PROVIDER=nebius python3 Companion/server.py 8124
```

The iPhone app calls this local companion. `GET /status` reports the active provider, agent, and model. Construction accepts the chosen policy, makes a Nebius chat-completions call, writes only `queued/queue.go` and `queued/worker.go`, and validates the immutable source boundary before publishing the candidate to the native view. The separate **Check** action runs Go build, vet, nine protected tests, and the revoked-access scenario against the exact candidate tree and accepted rule. A generated candidate is not described as verified until Check passes.

State and receipts persist across restarts. Response IDs, model identity, usage, request digests, and source digests are recorded; the key stays in the host environment. The companion binds to `127.0.0.1` and imports only the allowlisted synthetic repository. The [recorded run](../evidence/2026-10-30/manifest.json) has two model-generated candidates and two passing independent checks.

The source retains earlier Azure and Muse provider paths for development history. They are not the provider used in the recorded Nebius run.
