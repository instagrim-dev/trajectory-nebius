import Foundation
import Testing
@testable import WorkbenchCore

/// Decoding + mapping for the companion session snapshot. The JSON is a
/// small pinned literal in the shape the companion emits — never the
/// mutable checkout state or an absolute workstation path.
struct LiveSnapshotTests {
    // Pinned shape of GET /sessions/<sid> (field names must match
    // Companion/server.py exactly).
    private let pinned = """
    {"session_id": "abc123def456", "accepted_answer": "queue_time",
     "intents": [{"revision": 0, "answer": "queue_time"}],
     "repo": {"canonical": "instagrim-dev/trajectory-live-demo",
              "resolved_commit": "aaa"},
     "candidates": {"A": {"candidate": "A", "answer": "queue_time",
        "intent_revision": 0, "source_parent": "aaa", "tree": "treeA",
        "changed": ["queued/queue.go"], "commit": "ccc", "status": "pushed"}},
     "verifications": [{"candidate": "A", "tree": "treeA",
        "intent_revision": 0, "checker": {"id": "checker/1"},
        "passed": true, "failing_step": null,
        "tests_passed": ["TestRevokedAccess"], "scenario_status": "exported"}],
     "commits": [{"candidate": "A", "commit": "ccc", "parent": "aaa",
        "message": "A", "push": {"pushed": true, "deduplicated": false}}],
     "runs": [{"commit": "ccc", "run_id": 42, "attempt": 1,
        "conclusion": "success", "url": "https://example.invalid/r/42"}],
     "jobs": {}}
    """

    @Test("snapshot decodes and maps to live state")
    func decodesAndMaps() throws {
        let snapshot = try JSONDecoder().decode(
            LiveSessionSnapshot.self, from: Data(pinned.utf8))
        #expect(snapshot.sessionID == "abc123def456")
        #expect(snapshot.acceptedAnswer == .queueTime)
        #expect(snapshot.repoResolvedCommit == "aaa")
        let state = LiveState.fromSnapshot(snapshot)
        #expect(state.accepted == .queueTime)
        #expect(state.candidates["A"]?.commit == "ccc")
        #expect(state.candidates["A"]?.parentCandidate == nil)
        #expect(state.candidates["A"]?.generator == nil)
        #expect(state.binding == .current)
        #expect(state.viewedCommit?.pushed == true)
        #expect(state.viewedRun?.runID == 42)
    }

    @Test("missing optional sections decode to empty state")
    func emptyDecodes() throws {
        let snapshot = try JSONDecoder().decode(
            LiveSessionSnapshot.self,
            from: Data("{\"session_id\": \"abc123def456\"}".utf8))
        #expect(snapshot.acceptedAnswer == nil)
        #expect(snapshot.candidates.isEmpty)
        let state = LiveState.fromSnapshot(snapshot)
        #expect(state.accepted == nil)
        #expect(state.acceptedRevision == -1)
        #expect(state.acceptedTitle == "No answer accepted yet")
        #expect(state.binding == .unchecked)
    }
}
