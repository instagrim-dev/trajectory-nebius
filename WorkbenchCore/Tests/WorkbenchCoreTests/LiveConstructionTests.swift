import Foundation
import Testing
@testable import WorkbenchCore

/// Construction contract regressions. These use explicit test receipts and
/// never invoke a generator, start a check, or alter the retained A/B session.
struct LiveConstructionTests {
    @Test("request-time wording preserves the existing saved answer identifier")
    func requestTimePresentation() throws {
        #expect(LiveAnswer.queueTime.rawValue == "queue_time")
        #expect(LiveAnswer.queueTime.title == "Request-time authorization governs")
        #expect(LiveAnswer.queueTime.shortTitle == "Request time")
        #expect(Answer.queueTime.title == "Request-time authorization governs")
        #expect(SampleProgram.v1.versionLabel == "v1 · request-time")
        let stored = try JSONDecoder().decode(LiveAnswer.self, from: Data("\"queue_time\"".utf8))
        #expect(stored == .queueTime)
    }

    @Test("an empty session has no accepted rule and can explicitly accept B")
    func noInventedAcceptance() {
        var state = LiveState()
        state.select(.deliveryTime)
        #expect(state.accepted == nil)
        #expect(state.isAcceptEnabled)
        let accepted = state.accept()
        #expect(accepted)
        #expect(state.accepted == .deliveryTime)
        #expect(state.acceptedRevision == 0)
        #expect(state.candidates.isEmpty)
        #expect(state.verifications.isEmpty)
    }

    @Test("fresh names do not overwrite saved or pending candidate identities")
    func freshNames() {
        var state = LiveState()
        #expect(state.nextCandidateName(for: .queueTime) == "A")
        #expect(state.nextCandidateName(for: .deliveryTime) == "B")
        state.candidates["A"] = LiveCandidate(
            name: "A", answer: .queueTime, intentRevision: 0,
            sourceParent: "base-git", tree: "tree-A")
        state.candidates["B"] = LiveCandidate(
            name: "B", answer: .deliveryTime, intentRevision: 1,
            sourceParent: "commit-A", tree: "tree-B")
        let retained = state.candidates
        #expect(state.nextCandidateName(for: .queueTime) == "A-2")
        #expect(state.nextCandidateName(for: .deliveryTime, reserving: ["B-2"]) == "B-3")
        #expect(state.candidates == retained)
    }

    @Test("a failed build reserves its name after resume without becoming history")
    func failedAttemptSurvivesResume() throws {
        let json = """
        {"session_id":"test-session","accepted_answer":"delivery_time",
         "intents":[{"revision":0,"answer":"queue_time"},
                    {"revision":1,"answer":"delivery_time"}],
         "candidates":{"A":{"candidate":"A","answer":"queue_time",
           "intent_revision":0,"source_parent":"base-git","tree":"tree-A",
           "changed":["queued/worker.go"],"status":"generated"}},
         "jobs":{"failed-job":{"op":"construct","status":"failed",
           "params":{"candidate":"B","answer":"delivery_time"},
           "construction":{"candidate":"B"}},
           "queued-job":{"op":"construct","status":"queued",
             "params":{"candidate":"B-2","answer":"delivery_time"}}},
         "proposals":[{"candidate":"B-3","status":"failed"}]}
        """
        let snapshot = try JSONDecoder().decode(LiveSessionSnapshot.self, from: Data(json.utf8))
        let state = LiveState.fromSnapshot(snapshot, viewed: "A")
        #expect(state.accepted == .deliveryTime)
        #expect(state.viewed == "A")
        #expect(state.candidates.count == 1)
        #expect(state.candidates["B"] == nil)
        #expect(state.attemptedCandidateNames == ["B", "B-2", "B-3"])
        #expect(state.nextCandidateName(for: .deliveryTime) == "B-4")
        #expect(state.verifications.isEmpty)
        #expect(state.commits.isEmpty)
    }

    @Test("an uncommitted parent is linked by candidate and tree, not a shared Git base")
    func explicitTreeLineage() {
        let a2 = LiveCandidate(name: "A-2", answer: .queueTime, intentRevision: 2,
                              sourceParent: "base-git", tree: "tree-A2")
        var b2 = LiveCandidate(name: "B-2", answer: .deliveryTime, intentRevision: 3,
                              sourceParent: "base-git", tree: "tree-B2",
                              parentCandidate: "A-2", parentTree: "tree-A2",
                              baseGitCommit: "base-git")
        var state = LiveState(accepted: .deliveryTime, viewed: "B-2",
                              candidates: ["A-2": a2, "B-2": b2])
        #expect(state.parentCandidate(for: "B-2") == "A-2")
        #expect(state.mapBaseline(for: "B-2") == nil)
        #expect(state.candidates["B-2"]?.sourceParent == "base-git")
        b2.parentTree = "different-tree"
        state.candidates["B-2"] = b2
        #expect(state.parentCandidate(for: "B-2") == nil)
        #expect(state.mapBaseline(for: "B-2") == nil)
    }

    @Test("new construction provenance decodes while preserving the Git and tree identities")
    func provenanceDecoding() throws {
        let json = """
        {"session_id":"s","accepted_answer":"delivery_time",
         "candidates":{"B-2":{"candidate":"B-2","answer":"delivery_time",
           "intent_revision":3,"source_parent":"base-git","tree":"tree-B2",
           "parent_candidate":"A-2","parent_tree":"tree-A2",
           "base_git_commit":"base-git","changed":["queued/queue.go","queued/worker.go"],
           "status":"generated","generated_at":"2026-10-28T12:00:00Z",
           "generator":{"provider":"meta","tool":"muse exec","model":"test-model",
                        "session_id":"agent-session","exit_code":0}}}}
        """
        let snapshot = try JSONDecoder().decode(LiveSessionSnapshot.self, from: Data(json.utf8))
        let record = try #require(LiveState.fromSnapshot(snapshot).candidates["B-2"])
        #expect(record.parentCandidate == "A-2")
        #expect(record.parentTree == "tree-A2")
        #expect(record.sourceParent == "base-git")
        #expect(record.baseGitCommit == "base-git")
        #expect(record.generator?.provider == "meta")
        #expect(record.generator?.sessionID == "agent-session")
        #expect(record.status == "generated")
    }

    @Test("a run cannot receive another job or session's same-named candidate")
    func runIdentityRejectsStaleReplies() {
        let identity = LiveConstructionIdentity(sessionID: "one", jobID: "job-1", candidate: "A")
        #expect(identity.matches(sessionID: "one", jobID: "job-1", candidate: "A"))
        #expect(!identity.matches(sessionID: "two", jobID: "job-1", candidate: "A"))
        #expect(!identity.matches(sessionID: "one", jobID: "job-2", candidate: "A"))
        #expect(!identity.matches(sessionID: "one", jobID: "job-1", candidate: "B"))
    }

    @Test("observed source and final publication decode independently of check evidence")
    func observedSourceIsNotAPassingCheck() throws {
        let json = """
        {"candidate":"B-2","answer":"delivery_time","intent_revision":3,
         "source_parent":"base-git","parent_candidate":"A-2","parent_tree":"tree-A2",
         "provider":"meta","agent":"muse exec","model":"test-model",
         "generator_session_id":"agent-session","stage":"editing","provisional":true,
         "files":[{"path":"queued/worker.go","before":"if !job.PermissionSnapshot {",
            "after":"if !access.Allowed(job.TenantID, job.UserID) {",
            "diff":"-if !job.PermissionSnapshot {\\n+if !access.Allowed(job.TenantID, job.UserID) {",
            "sha256":"observed-file-hash"}],
         "events":[{"id":"job:1","at":"2026-10-28T12:00:00Z",
                    "kind":"source_changed","message":"Observed worker.go save"}]}
        """
        var construction = try JSONDecoder().decode(LiveConstruction.self, from: Data(json.utf8))
        #expect(construction.files.first?.path == "queued/worker.go")
        #expect(construction.changedFiles.count == 1)
        #expect(construction.events.first?.id == "job:1")
        #expect(!construction.hasPublishedCandidate)
        construction.stage = "succeeded"
        construction.outputTree = "tree-B2"
        construction.changedPaths = ["queued/queue.go", "queued/worker.go"]
        #expect(construction.changedPaths?.count == 2)
        #expect(construction.changedFiles.count == 1) // Safe previews can be a subset.
        #expect(!construction.hasPublishedCandidate) // Still provisional.
        construction.provisional = false
        #expect(construction.hasPublishedCandidate)
        construction.stage = "failed"
        #expect(!construction.hasPublishedCandidate)
    }

    @Test("viewing new B-2 cannot borrow old B checks and return navigation is dynamic")
    func completedArtifactStaysUnchecked() {
        let b = LiveCandidate(name: "B", answer: .deliveryTime, intentRevision: 1,
                              sourceParent: "commit-A", tree: "tree-B", commit: "commit-B")
        let b2 = LiveCandidate(name: "B-2", answer: .deliveryTime, intentRevision: 3,
                               sourceParent: "commit-B", tree: "tree-B2",
                               parentCandidate: "B", parentTree: "tree-B", status: "generated")
        var state = LiveState(accepted: .deliveryTime, acceptedRevision: 3,
                              viewed: "B-2", candidates: ["B": b, "B-2": b2],
                              verifications: [LiveVerification(
                                candidate: "B", tree: "tree-B", intentRevision: 1,
                                checkerID: "checker", passed: true, scenarioStatus: "access_revoked")],
                              runs: [LiveRun(commit: "commit-B", runID: 1, attempt: 1,
                                             conclusion: "success")])
        #expect(state.binding == .unchecked)
        #expect(state.viewedConsequence == nil)
        #expect(state.viewedRun == nil)
        #expect(state.latestCandidateMatchingAccepted == "B-2")
        let retained = state.candidates
        state.openCandidate("B")
        #expect(state.accepted == .deliveryTime)
        #expect(state.latestCandidateMatchingAccepted == "B-2")
        #expect(state.candidates == retained)
        #expect(state.viewedRun?.runID == 1)
    }
}
