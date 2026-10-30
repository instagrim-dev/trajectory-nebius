import Testing
@testable import WorkbenchCore

struct LiveOperationTests {
    @Test("completion follows the candidate, tree, and latest outcome")
    func completionIsBoundToEvidence() {
        var a = LiveCandidate(name: "A", answer: .queueTime, intentRevision: 1,
                              sourceParent: "base", tree: "treeA", commit: "commitA")
        var state = LiveState(candidates: ["A": a])
        #expect(!state.operationSucceeded(.check, for: "A"))
        state.verifications = [LiveVerification(candidate: "A", tree: "treeA", intentRevision: 1,
                                               checkerID: "check", passed: true)]
        #expect(state.operationSucceeded(.check, for: "A"))
        #expect(!state.operationSucceeded(.check, for: "B"))
        a.tree = "changed"
        state.candidates["A"] = a
        #expect(!state.operationSucceeded(.check, for: "A"))
        a.tree = "treeA"
        state.candidates["A"] = a
        state.verifications.append(LiveVerification(candidate: "A", tree: "treeA", intentRevision: 1,
                                                    checkerID: "check", passed: false))
        #expect(!state.operationSucceeded(.check, for: "A"))
        #expect(state.operationSucceeded(.commit, for: "A"))
        #expect(!state.operationSucceeded(.push, for: "A"))
        state.commits = [LiveCommit(candidate: "A", commit: "other", parent: "base", message: "", pushed: true)]
        #expect(!state.operationSucceeded(.push, for: "A"))
        state.commits.append(LiveCommit(candidate: "A", commit: "commitA", parent: "base", message: "", pushed: true))
        #expect(state.operationSucceeded(.push, for: "A"))
        state.runs = [LiveRun(commit: "other", runID: 1, attempt: 1, conclusion: "success")]
        #expect(!state.operationSucceeded(.observe, for: "A"))
        state.runs.append(LiveRun(commit: "commitA", runID: 2, attempt: 1, conclusion: "failure"))
        #expect(!state.operationSucceeded(.observe, for: "A"))
        state.runs.append(LiveRun(commit: "commitA", runID: 2, attempt: 2, conclusion: "success"))
        #expect(state.operationSucceeded(.observe, for: "A"))
    }

    @Test("presentation uses synthesis wording without changing stored stages")
    func synthesisPresentation() {
        #expect(liveConstructionStageTitle("invoking") == "synthesizing")
        #expect(liveConstructionStageTitle("editing") == "editing")
    }
}
