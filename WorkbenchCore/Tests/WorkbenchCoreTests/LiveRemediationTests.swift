import Testing
@testable import WorkbenchCore

/// Quorum remediation regressions: truthful ancestry from immutable
/// records, plain-language consequence bound to observed outcomes, and
/// guard excerpts sliced from fetched source — all independent of the
/// mutable current repository head.
struct LiveRemediationTests {
    // Real immutable identities from saved session ad6186198e7d.
    private let baseline = "b6b929cec75f0fe2b3ad82c2cdb55e127e1709e6"
    private let commitA = "5adf3fa8626fb062ab9e92294e09995e511d548c"
    private let commitB = "4bdb6c0cc000e2a5c8bfa6640dcb420fe87ad8b2"

    private func finishedState(viewed: String = "B") -> LiveState {
        let a = LiveCandidate(name: "A", answer: .queueTime,
                              intentRevision: 0, sourceParent: baseline,
                              tree: "c23e2d902325bd7233d1911fe43f32663b6cf412853c9eec112ff9cc6ad28218",
                              changedFiles: ["queued/queue.go", "queued/worker.go"],
                              commit: commitA)
        let b = LiveCandidate(name: "B", answer: .deliveryTime,
                              intentRevision: 1, sourceParent: commitA,
                              tree: "6982a8daba955ecb29eede89e007210781fd9172ee01b63dcbfc10e713fd49d6",
                              changedFiles: ["queued/queue.go", "queued/worker.go"],
                              commit: commitB)
        return LiveState(selected: .deliveryTime, accepted: .deliveryTime,
                         acceptedRevision: 1, viewed: viewed,
                         candidates: ["A": a, "B": b],
                         verifications: [
                            LiveVerification(candidate: "A",
                                             tree: "c23e2d902325bd7233d1911fe43f32663b6cf412853c9eec112ff9cc6ad28218",
                                             intentRevision: 0,
                                             checkerID: "checker/1", passed: true,
                                             testsPassed: ["TestRevokedAccess"],
                                             scenarioStatus: "exported"),
                            LiveVerification(candidate: "B",
                                             tree: "6982a8daba955ecb29eede89e007210781fd9172ee01b63dcbfc10e713fd49d6",
                                             intentRevision: 1,
                                             checkerID: "checker/1", passed: true,
                                             testsPassed: ["TestRevokedAccess"],
                                             scenarioStatus: "access_revoked"),
                         ],
                         commits: [
                            LiveCommit(candidate: "A", commit: commitA,
                                       parent: baseline, message: "A"),
                            LiveCommit(candidate: "B", commit: commitB,
                                       parent: commitA, message: "B"),
                         ],
                         runs: [
                            LiveRun(commit: commitA, runID: 40535341214,
                                    attempt: 1, conclusion: "success", url: "u"),
                            LiveRun(commit: commitB, runID: 40543004225,
                                    attempt: 1, conclusion: "success", url: "v"),
                         ])
    }

    @Test("map baseline is the immutable source parent, not the current head")
    func ancestryIgnoresMutableHead() {
        var state = finishedState()
        // The current repository head is B after B lands; the map must
        // still root A at the imported baseline, never at B or at A.
        #expect(state.parentCandidate(for: "A") == nil)
        #expect(state.parentCandidate(for: "B") == "A")
        #expect(state.mapBaseline(for: "A") == String(baseline.prefix(12)))
        #expect(state.mapBaseline(for: "B") == nil)
        // B → A → B traversal changes viewed state only; ancestry,
        // accepted intent, and evidence counts stay fixed.
        let counts = (state.candidates.count, state.verifications.count,
                      state.commits.count)
        state.openCandidate("A")
        #expect(state.mapBaseline(for: "A") == String(baseline.prefix(12)))
        #expect(state.parentCandidate(for: "B") == "A")
        state.openCandidate("B")
        #expect(state.mapBaseline(for: "A") == String(baseline.prefix(12)))
        #expect(state.parentCandidate(for: "B") == "A")
        #expect(state.accepted == .deliveryTime)
        #expect((state.candidates.count, state.verifications.count,
                 state.commits.count) == counts)
    }

    @Test("unknown candidate has no ancestry label")
    func unknownCandidateHasNoBaseline() {
        let state = finishedState()
        #expect(state.parentCandidate(for: "Z") == nil)
        #expect(state.mapBaseline(for: "Z") == nil)
    }

    @Test("consequence follows the observed scenario outcome per viewed candidate")
    func consequenceBindsObservedOutcome() {
        var state = finishedState(viewed: "A")
        #expect(state.binding == .historical)
        #expect(state.viewedConsequence == "Access was revoked while queued. The customer records package was still released.")
        state.openCandidate("B")
        #expect(state.binding == .current)
        #expect(state.viewedConsequence == "Access was revoked while queued. Delivery was blocked; nothing was released.")
    }

    @Test("failed or mismatched evidence yields no release/block claim")
    func noConsequenceWithoutPassingApplicableEvidence() {
        var state = finishedState(viewed: "B")
        #expect(state.viewedConsequence != nil)
        // A failed check on the same tree is still the applicable
        // evidence — and it must not claim a release or a block.
        state.verifications = [LiveVerification(
            candidate: "B",
            tree: "6982a8daba955ecb29eede89e007210781fd9172ee01b63dcbfc10e713fd49d6",
            intentRevision: 1, checkerID: "checker/1", passed: false,
            failingStep: "test", scenarioStatus: "access_revoked")]
        #expect(state.viewedConsequence == nil)
        // A moved tree mismatches retained evidence: also no claim.
        state = finishedState(viewed: "B")
        state.candidates["B"]?.tree = "tampered"
        #expect(state.binding == .mismatched)
        #expect(state.viewedConsequence == nil)
        // An unknown scenario status claims nothing either.
        state = finishedState(viewed: "B")
        state.verifications = [LiveVerification(
            candidate: "B",
            tree: "6982a8daba955ecb29eede89e007210781fd9172ee01b63dcbfc10e713fd49d6",
            intentRevision: 1, checkerID: "checker/1", passed: true,
            testsPassed: ["TestRevokedAccess"], scenarioStatus: "denied")]
        #expect(state.viewedConsequence == nil)
    }

    @Test("context line names accepted intent and viewed cursor")
    func contextLine() {
        var state = finishedState(viewed: "A")
        #expect(state.contextLine == "Accepted: delivery-time · Viewing: A (historical)")
        state.openCandidate("B")
        #expect(state.contextLine == "Accepted: delivery-time · Viewing: B (current)")
    }

    @Test("guard excerpt is a slice of the fetched worker source")
    func guardExcerptSlicesFetchedSource() {
        let workerA = """
            func Deliver(job Job, actorTenant string, access Access, audit func(Event) error) Outcome {
            \tif actorTenant != job.TenantID {
            \t\treturn Outcome{Status: "denied", Events: []Event{}}
            \t}
            \tif !job.PermissionSnapshot {
            \t\treturn Outcome{Status: "access_revoked", Events: []Event{}}
            \t}
            \treturn complete(job, audit)
            }
            """
        let workerB = """
            func Deliver(job Job, actorTenant string, access Access, audit func(Event) error) Outcome {
            \tif actorTenant != job.TenantID {
            \t\treturn Outcome{Status: "denied", Events: []Event{}}
            \t}
            \tif !access.Allowed(job.TenantID, job.UserID) {
            \t\treturn Outcome{Status: "access_revoked", Events: []Event{}}
            \t}
            \treturn complete(job, audit)
            }
            """
        let excerptA = decisiveGuardExcerpt(sourceText: workerA)
        let excerptB = decisiveGuardExcerpt(sourceText: workerB)
        #expect(excerptA != nil && workerA.contains(excerptA!))
        #expect(excerptB != nil && workerB.contains(excerptB!))
        #expect(excerptA!.contains("if !job.PermissionSnapshot {"))
        #expect(excerptB!.contains("if !access.Allowed(job.TenantID, job.UserID) {"))
        #expect(excerptA != excerptB)
        #expect(decisiveGuardExcerpt(sourceText: "package queued\n") == nil)
        #expect(decisiveGuardExcerpt(sourceText: "") == nil)
    }
}
