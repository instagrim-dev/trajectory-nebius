# Trajectory: decisions you can inspect

Trajectory is a native iPhone/iPad decision workbench with a local Mac companion. A privacy analyst must choose whether a queued customer-records export uses the permission saved when the request was queued or re-checks permission at delivery. **NVIDIA Nemotron 3.5 Lightning through Nebius Token Factory** constructs the two permitted Go source files for the chosen rule. The app shows the actual changes, while the companion independently builds, vets, tests, and runs the request → revoke → deliver scenario. Saved candidates remain inspectable when the owner changes their answer.

The [public synthetic service](https://github.com/instagrim-dev/trajectory-nebius-demo) is the import target. It contains the protected tests and a delivery-time baseline. No customer records are used. Model-generated code can change only `queued/queue.go` and `queued/worker.go`; the source boundary is checked before a candidate appears in the app. Passing checks are a separate action and are bound to the exact source tree and accepted rule.

## Run on a Mac

Requires Xcode 27.1 with an iOS Simulator, Python 3.11+, Git, and Go 1.27. Set your Nebius Token Factory key in the Mac host environment; it is never put in the iOS app or repository.

```sh
export NEBIUS_API_KEY=...   # supply privately in your shell
TRAJECTORY_GENERATOR_PROVIDER=nebius python3 Companion/server.py 8124
```

Open `Workbench.xcodeproj`, select the `Workbench` scheme and an iPhone simulator, then Run. Open **Live** → **Connect and import**. Choose **Request time** and **Accept and build A**; wait for the actual Nemotron construction. Tap **Check** separately. Choose **Delivery time** and **Accept and build B** from saved A, then **Check** B. The same revoked-access scenario exports under A and blocks under B. `python3 -m unittest discover -s Companion/tests` and `swift test --package-path WorkbenchCore` run the local suites without provider calls.

The companion serves only `127.0.0.1:8124` and imports the allowlisted demo repository. The model path makes one Nebius `/v1/chat/completions` call per construction, with no automatic retry. It records the returned model identity, response ID, usage, request digest, and candidate source digests; raw keys are never recorded. The local Check runs `go build`, `go vet`, nine protected tests, and the visible scenario. GitHub Actions are not required for this submission.

## Scope and provenance

BMO's aggregate engine and public decision-guided synthesis design predate this hackathon. Trajectory's native workbench and standalone companion were built during the submission period. Earlier development runs used Muse and an interim Azure path; the Nebius provider and the recorded Nemotron A/B construction were added October 30, 2026. The standalone companion shown here does not demonstrate a live BMO runtime integration. This is a bounded synthetic policy choice, not arbitrary-repository synthesis or a production privacy system.

The `Companion/fixtures/delivery-baseline` tree is a local test fixture. The public service linked above is the judge import target. Source and tests are MIT licensed; this license does not extend to the separate BMO engine.
