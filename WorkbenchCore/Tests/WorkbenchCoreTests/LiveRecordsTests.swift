import Testing
@testable import WorkbenchCore

/// Live binding and traversal invariants: applicability derives from
/// actual content identity (candidate tree + verified tree + accepted
/// answer), never from a hand-set flag or a sample fixture hash.
struct LiveRecordsTests {
    @Test("history keeps descendants beside parents and retains unresolved nodes")
    func historyOrderFollowsAncestry() {
        func candidate(_ name: String, parent: String? = nil, parentTree: String? = nil) -> LiveCandidate {
            LiveCandidate(name: name, answer: .deliveryTime, intentRevision: 0,
                          sourceParent: "baseline", tree: "tree-\(name)",
                          parentCandidate: parent, parentTree: parentTree)
        }
        let candidates = [candidate("A"), candidate("B", parent: "A", parentTree: "tree-A"),
                          candidate("A-2", parent: "B", parentTree: "tree-B"),
                          candidate("B-2", parent: "A", parentTree: "tree-A"),
                          candidate("C", parent: "missing", parentTree: "unknown")]
        let state = LiveState(candidates: Dictionary(uniqueKeysWithValues: candidates.map { ($0.name, $0) }))
        #expect(state.historyOrder.map(\.name) == ["A", "B", "A-2", "B-2", "C"])
        #expect(state.historyOrder.map(\.depth) == [0, 1, 2, 1, 0])
        #expect(state.historyOrder.count == candidates.count)
    }

    @Test("cyclic candidate ancestry remains visible without repeating nodes")
    func cyclicHistoryIsBounded() {
        let a = LiveCandidate(name: "A", answer: .queueTime, intentRevision: 0,
                              sourceParent: "base", tree: "a", parentCandidate: "B", parentTree: "b")
        let b = LiveCandidate(name: "B", answer: .queueTime, intentRevision: 0,
                              sourceParent: "base", tree: "b", parentCandidate: "A", parentTree: "a")
        let state = LiveState(candidates: ["A": a, "B": b])
        #expect(state.historyOrder.map(\.name) == ["A", "B"])
    }
    @Test("candidate check summaries use exact source and latest result")
    func candidateCheckSummaries() {
        let a = candidateA()
        let b = LiveCandidate(name: "B", answer: .deliveryTime, intentRevision: 1,
                              sourceParent: "baseline", tree: "treeB", status: "check_failed")
        var state = LiveState(accepted: .deliveryTime, viewed: "B",
                              candidates: ["A": a, "B": b], verifications: [pass(tree: "treeA")])
        #expect(state.checkSummary(for: "A") == .passed)
        #expect(state.checkSummary(for: "B") == .notChecked)
        state.verifications.append(LiveVerification(candidate: "B", tree: "treeB", intentRevision: 1,
                                                    checkerID: "checker/1", passed: false, failingStep: "test"))
        #expect(state.checkSummary(for: "B") == .failed)
        #expect(state.checkSummary(for: "A") == .passed)
        state.candidates["A"]?.tree = "changed"
        #expect(state.checkSummary(for: "A") == .stale)
        #expect(state.checkSummary(for: "missing") == .notChecked)
        state.verifications.append(LiveVerification(candidate: "B", tree: "treeB", intentRevision: 1,
                                                    checkerID: "checker/1", passed: true))
        #expect(state.checkSummary(for: "B") == .passed)
    }
    private func candidateA(tree: String = "treeA",
                            answer: LiveAnswer = .queueTime) -> LiveCandidate {
        LiveCandidate(name: "A", answer: answer, intentRevision: 0,
                      sourceParent: "baseline", tree: tree,
                      changedFiles: ["queued/queue.go", "queued/worker.go"])
    }

    private func pass(tree: String, answerRev: Int = 0) -> LiveVerification {
        LiveVerification(candidate: "A", tree: tree, intentRevision: answerRev,
                         checkerID: "checker/1", passed: true,
                         testsPassed: ["TestRevokedAccess"],
                         scenarioStatus: "exported")
    }

    @Test("accept changes intent only; select never accepts")
    func acceptIsIntentOnly() {
        var state = LiveState(accepted: .deliveryTime)
        state.select(.queueTime)
        #expect(state.selected == .queueTime)
        #expect(state.accepted == .deliveryTime)
        #expect(state.isAcceptEnabled)
        let changed = state.accept()
        #expect(changed)
        #expect(state.accepted == .queueTime)
        #expect(state.acceptedRevision == 1)
        let unchanged = state.accept()
        #expect(!unchanged)
        #expect(state.acceptedRevision == 1)
    }

    @Test("current binding needs a pass on the exact viewed tree under accepted intent")
    func currentBinding() {
        var state = LiveState(accepted: .queueTime,
                              candidates: ["A": candidateA()])
        #expect(state.binding == .unchecked)
        state.verifications = [pass(tree: "treeA")]
        #expect(state.binding == .current)
    }

    @Test("viewed tree differing from the verified tree is mismatched, not unchecked")
    func staleTreeIsMismatched() {
        var a = candidateA()
        var state = LiveState(accepted: .queueTime,
                              candidates: ["A": a],
                              verifications: [pass(tree: "treeA")])
        #expect(state.binding == .current)
        a.tree = "treeA-tampered"
        state.candidates["A"] = a
        let stale: LiveVerification? = state.viewedVerificationForTree
        #expect(stale == nil)
        #expect(state.binding == .mismatched)
    }

    @Test("failed verification on the current tree is current evidence with a failed outcome")
    func failedCheckIsCurrentAndFailed() {
        let state = LiveState(accepted: .queueTime,
                              candidates: ["A": candidateA()],
                              verifications: [
                                LiveVerification(candidate: "A", tree: "treeA",
                                                 intentRevision: 0,
                                                 checkerID: "checker/1",
                                                 passed: false,
                                                 failingStep: "test")])
        // Applicability is orthogonal to pass/fail: the failed check
        // applies to exactly this tree, so it is current — and failed.
        #expect(state.binding == .current)
        #expect(state.viewedVerificationForTree?.passed == false)
        let pass: LiveVerification? = state.viewedPass
        #expect(pass == nil)
    }

    @Test("verification for a superseded intent revision is mismatched, not current")
    func supersededRevisionIsMismatched() {
        var a = candidateA()
        a.intentRevision = 1
        let state = LiveState(accepted: .queueTime,
                              candidates: ["A": a],
                              verifications: [pass(tree: "treeA", answerRev: 0)])
        #expect(state.viewedVerificationForTree == nil)
        #expect(state.binding == .mismatched)
    }

    @Test("historical binding when accepted intent moves away")
    func historicalAfterRevision() {
        var state = LiveState(accepted: .queueTime,
                              candidates: ["A": candidateA()],
                              verifications: [pass(tree: "treeA")])
        #expect(state.binding == .current)
        state.select(.deliveryTime)
        state.accept()
        #expect(state.accepted == .deliveryTime)
        #expect(state.binding == .historical)
    }

    @Test("reopening a historical candidate never changes accepted intent or evidence")
    func traversalIsReadOnly() {
        let b = LiveCandidate(name: "B", answer: .deliveryTime,
                              intentRevision: 1, sourceParent: "commitA",
                              tree: "treeB", commit: "commitB")
        var state = LiveState(selected: .deliveryTime, accepted: .deliveryTime,
                              acceptedRevision: 1, viewed: "B",
                              candidates: ["A": candidateA(), "B": b],
                              verifications: [pass(tree: "treeA"),
                                              LiveVerification(
                                                candidate: "B", tree: "treeB",
                                                intentRevision: 1,
                                                checkerID: "checker/1",
                                                passed: true,
                                                scenarioStatus:
                                                  "access_revoked")])
        #expect(state.binding == .current)
        state.openCandidate("A")
        #expect(state.viewed == "A")
        #expect(state.accepted == .deliveryTime)
        #expect(state.acceptedRevision == 1)
        #expect(state.binding == .historical)
        state.openCandidate("B")
        #expect(state.binding == .current)
        #expect(state.viewedRun == nil)
    }

    @Test("viewed run binds to the candidate's exact commit only")
    func runBindsExactCommit() {
        let b = LiveCandidate(name: "B", answer: .deliveryTime,
                              intentRevision: 1, sourceParent: "commitA",
                              tree: "treeB", commit: "commitB")
        var state = LiveState(accepted: .deliveryTime, viewed: "B",
                              candidates: ["B": b],
                              runs: [LiveRun(commit: "commitA", runID: 1,
                                             attempt: 1, conclusion:
                                               "success",
                                             url: "https://example.invalid/a")])
        // A run for another commit is not borrowed.
        #expect(state.viewedRun == nil)
        state.runs = [LiveRun(commit: "commitB", runID: 2, attempt: 1,
                              conclusion: "success",
                              url: "https://example.invalid/b")]
        #expect(state.viewedRun?.runID == 2)
    }

    @Test("commit of another candidate is never shown as viewed")
    func commitBindsCandidate() {
        let state = LiveState(
            viewed: "B",
            candidates: ["A": candidateA(),
                         "B": LiveCandidate(name: "B", answer: .deliveryTime,
                                            intentRevision: 1,
                                            sourceParent: "commitA",
                                            tree: "treeB")],
            commits: [LiveCommit(candidate: "A", commit: "commitA",
                                 parent: "baseline", message: "A")])
        #expect(state.viewedCommit == nil)
    }
}
