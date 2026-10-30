# Native companion

Start the interim Azure OpenAI generator from the project root:

```sh
python3 Companion/run_azure.py 8123
```

For the hackathon's Baseten endpoint, make `BASETEN_API_KEY` available in the host environment and start the companion with:

```sh
TRAJECTORY_GENERATOR_PROVIDER=baseten python3 Companion/server.py 8123
```

This selects Muse Code and the hackathon model `meta-models/muse-spark-open-1026` at `https://inference.baseten.co/v1`. The key stays on the host and is passed to Muse on standard input. This path still requires a successful live generation and compatibility check before it can be used as submission evidence.

The launcher reads the existing host setup in
`~/.config/bmo-azure-codex/state.json` and its sibling credential file.
`TRAJECTORY_AZURE_CONFIG_DIR` can select another existing setup directory.
Credentials remain in the host process environment; the native app and
generation receipts contain provider, agent, deployment and session identities.

Azure uses `codex exec` with the configured execution deployment. The bare
`server.py` retains the original Meta/Muse default; select `baseten` explicitly
for the hackathon endpoint.

`GET /status` reports the active provider, agent and model. Construction accepts
the chosen rule, generates only `queued/queue.go` and `queued/worker.go`, observes
saved edits, and validates the mutation boundary. Compilation, vet, tests and
the revoked-access scenario run through the separate **Check** action.

The retained state directory and existing candidate identities are preserved
across restarts. Publication and licensing remain **ON HOLD**.
