import Foundation
import Observation
import WorkbenchCore

/// Connected-repository state for the live workbench. The conversation
/// spine and sample mode are untouched; this model drives the Live tab
/// only, through real companion operations.
///
/// Selecting or viewing never accepts or constructs. The explicitly named
/// Accept & build action is the only compound action; checks, commits,
/// pushes, and CI observation remain separate.
@Observable
final class LiveWorkbenchModel {
    static let demoRepo = "instagrim-dev/trajectory-nebius-demo"

    let client = LiveCompanionClient()

    var sessionID: String?
    /// Durable-workspace resume: a developer can reopen a saved
    /// companion session (created on an earlier launch) by session ID.
    /// Resume only fetches persisted companion/GitHub truth — it never
    /// invents candidates, intent, or evidence. The last used session
    /// ID persists across launches for normal relaunch.
    var resumeSessionID = UserDefaults.standard.string(forKey: "liveResumeSessionID") ?? ""
    var state = LiveState()
    var repoCanonical: String?
    var repoCommit: String?

    var activeJob: LiveCompanionClient.Job?
    var activeOp: String?
    var isSubmitting = false
    /// Retained after activeJob clears. Its identity never follows the
    /// saved-candidate cursor, and its files come only from job responses.
    var constructionJob: LiveCompanionClient.Job?
    var constructionIdentity: LiveConstructionIdentity?
    var constructionFilePath = "queued/worker.go"
    private var reservedCandidateNames: Set<String> = []
    var lastError: String?
    var lastNextAction: String?
    var lastResult: String?

    var candidateName = "A"
    var commitMessage = ""
    var diffText = ""
    /// Which candidate the visible diff was loaded for. Diff replies
    /// are keyed by viewed identity; a stale reply never overwrites
    /// another candidate's text.
    var diffLoadedFor = ""
    var sourceText = ""
    /// "candidate|path" the visible source was loaded for.
    var sourceLoadedFor = ""
    var sourcePath = "queued/worker.go"
    private var sourceRequestID = UUID()
    private var diffRequestID = UUID()

    var isConnected: Bool { sessionID != nil && repoCommit != nil }

    var statusLine: String {
        if let job = activeJob, !job.isTerminal {
            let phase = job.construction.map { liveConstructionStageTitle($0.stage) } ?? job.note ?? job.status
            return "\(activeOp ?? job.op) · \(phase)"
        }
        if isSubmitting { return "Submitting \(activeOp ?? "request")…" }
        if let error = lastError { return "Failed: \(error)" }
        if let result = lastResult { return result }
        if isConnected { return "Connected · awaiting action" }
        return "Not connected"
    }

    // MARK: - Select vs accept vs view (all intent-safe)

    func select(_ answer: LiveAnswer) { state.select(answer) }

    func openCandidate(_ name: String) {
        guard state.candidates[name] != nil else { return }
        state.openCandidate(name)
        candidateName = name
        lastError = nil
        lastNextAction = nil
        // Viewing is read-only, but the previously viewed candidate's
        // source/diff must not linger under the new heading: clear both
        // and reload explicitly, so headings, source, diff and evidence
        // always describe the same viewed node.
        sourceText = ""
        sourceLoadedFor = ""
        diffText = ""
        diffLoadedFor = ""
        sourceRequestID = UUID()
        diffRequestID = UUID()
    }

    @MainActor
    func viewSavedCandidate(_ name: String) async {
        openCandidate(name)
        sourcePath = "queued/worker.go"
        await loadSource()
        await loadDiff()
    }

    func nextCandidateName(for answer: LiveAnswer) -> String {
        state.nextCandidateName(for: answer, reserving: reservedCandidateNames)
    }

    var constructionParent: LiveCandidate? { state.candidates[state.viewed] }

    var constructionParentLine: String {
        if let parent = constructionParent {
            return "Parent: saved \(parent.name) · tree \(parent.tree.prefix(12))"
        }
        if let repoCommit { return "Parent: repository baseline \(repoCommit.prefix(12))" }
        return "Connect or resume a repository to choose a source parent."
    }

    var returnCandidateName: String? {
        guard let name = state.latestCandidateMatchingAccepted,
              name != state.viewed else { return nil }
        return name
    }

    // MARK: - Refresh

    @MainActor
    func refresh() async {
        guard let sid = sessionID else { return }
        do {
            let snapshot = try await client.session(sid)
            guard sessionID == sid else { return }
            apply(snapshot)
        } catch {
            guard sessionID == sid else { return }
            lastError = error.localizedDescription
            lastNextAction = "Check the companion is running, then reconnect."
        }
    }

    @MainActor
    private func apply(_ snapshot: LiveSessionSnapshot) {
        let selected = state.selected
        let viewed = state.viewed
        state = LiveState.fromSnapshot(snapshot, selected: selected, viewed: viewed)
        repoCanonical = snapshot.repoCanonical
        repoCommit = snapshot.repoResolvedCommit
    }

    // MARK: - Operations

    @MainActor
    func connect() async {
        guard !busy else { return }
        isSubmitting = true
        activeOp = "import"
        defer { isSubmitting = false }
        lastError = nil
        lastNextAction = nil
        lastResult = nil
        do {
            let created = try await client.createSession()
            resetPresentationForSession()
            sessionID = created.sessionID
            resumeSessionID = created.sessionID
            UserDefaults.standard.set(created.sessionID, forKey: "liveResumeSessionID")
            let job = try await client.importRepo(created.sessionID,
                                                  repo: Self.demoRepo, ref: "main")
            let done = try await track(job, op: "import", sid: created.sessionID)
            guard done.status == "succeeded" else { throw jobFailed(done, "import") }
            await refresh()
            lastResult = "Imported \(Self.demoRepo) at \(String((repoCommit ?? "").prefix(12)))"
        } catch {
            note(error, action: "Verify the companion is running on this Mac, then tap Connect again.")
        }
    }

    /// Reopen a saved companion session in this workspace. Read-only
    /// fetch of persisted actual state: the snapshot supplies accepted
    /// intent, immutable candidates, verifications, commits, and runs.
    /// Nothing is generated, accepted, or synthesized here.
    @MainActor
    func resume() async {
        guard !busy else { return }
        let sid = resumeSessionID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !sid.isEmpty else {
            noteText("No session ID entered.",
                     action: "Enter a saved session ID, then tap Resume session.")
            return
        }
        lastError = nil
        lastNextAction = nil
        lastResult = nil
        isSubmitting = true
        activeOp = "resume"
        defer { isSubmitting = false }
        do {
            let snapshot = try await client.session(sid)
            if sessionID != snapshot.sessionID { resetPresentationForSession() }
            sessionID = snapshot.sessionID
            resumeSessionID = snapshot.sessionID
            UserDefaults.standard.set(snapshot.sessionID, forKey: "liveResumeSessionID")
            apply(snapshot)
            // Viewing follows the persisted cursor default; the
            // accepted intent comes from the snapshot, never the UI.
            candidateName = state.viewed
            lastResult = "Resumed session \(String(snapshot.sessionID.prefix(8))) · \(state.acceptedTitle). Nothing was regenerated."
            await loadSource()
            await loadDiff()
        } catch {
            note(error, action: "Check the session ID and that the companion is running, then resume again.")
        }
    }

    @MainActor
    func accept() async {
        guard let sid = sessionID else { return }
        guard state.isAcceptEnabled, !busy else { return }
        let answer = state.selected
        isSubmitting = true
        activeOp = "accept"
        defer { isSubmitting = false }
        lastError = nil
        lastNextAction = nil
        do {
            _ = try await client.accept(sid, answer: answer)
            guard sessionID == sid else { return }
            await refresh()
            lastResult = "Accepted \(state.acceptedTitle) as owner intent. Nothing was generated."
        } catch {
            note(error, action: "Tap Accept selected answer again.")
        }
    }

    /// The label on this action says exactly what it does: accept this
    /// answer, then build a fresh candidate from the currently viewed tree.
    @MainActor
    func construct(_ answer: LiveAnswer) async {
        guard let sid = sessionID, isConnected, !busy else { return }
        // Set before the first await. A second tap cannot allocate a second
        // request while the initial POST is still in flight.
        isSubmitting = true
        activeOp = "accept & build"
        defer { isSubmitting = false }
        let name = nextCandidateName(for: answer)
        let parent = constructionParent
        reservedCandidateNames.insert(name)
        state.select(answer)
        lastError = nil
        lastNextAction = nil
        lastResult = nil
        constructionJob = nil
        constructionIdentity = nil
        constructionFilePath = "queued/worker.go"
        do {
            let job = try await client.construct(
                sid, candidate: name, answer: answer,
                parentCandidate: parent?.name, parentTree: parent?.tree)
            guard sessionID == sid else { return }
            constructionIdentity = LiveConstructionIdentity(
                sessionID: sid, jobID: job.jobID, candidate: name)
            let done = try await track(job, op: "accept & build", sid: sid)
            guard sessionID == sid else { return }
            await refresh()
            if done.status == "succeeded",
               let detail = done.construction, detail.hasPublishedCandidate,
               state.candidates[name]?.tree == detail.outputTree {
                await viewSavedCandidate(name)
                lastResult = "Built \(name) · tree \(String((detail.outputTree ?? "").prefix(12))). Construction did not run checks."
            } else if done.status == "succeeded" {
                noteText("Construction returned without a matching retained tree.",
                         action: "Refresh this session before using the result.")
            } else {
                throw jobFailed(done, "construction")
            }
        } catch let failed as JobFailed {
            await refresh()
            lastError = "Construction \(failed.job.status): \(failed.job.error ?? failed.job.construction?.error ?? "see run details")"
            lastNextAction = "No candidate was published by this run. Inspect the recorded failure; another build uses a fresh name."
        } catch {
            await refresh()
            note(error, action: "Check this session's recorded run before retrying. The request may have reached the companion.")
        }
    }

    @MainActor
    func generate() async {
        let name = candidateName
        await runJob(op: "generate", nextName: name) { sid in
            try await self.client.generate(sid, candidate: name)
        } success: { job in
            "Generated candidate \(name) · tree \(String((job.result?.tree ?? "").prefix(12))). Awaiting checks."
        } failure: { _ in "Fix the boundary violation, then generate under a new name." }
    }

    @MainActor
    func check() async {
        let name = candidateName
        await runJob(op: "check", nextName: name) { sid in
            try await self.client.check(sid, candidate: name)
        } success: { job in
            if job.result?.passed == true {
                let outcome: String
                switch job.result?.scenarioStatus {
                case "exported": outcome = "Customer records package released after access was revoked."
                case "access_revoked": outcome = "Customer records package blocked after access was revoked."
                default: outcome = "See the scenario result for this candidate."
                }
                return "Checks passed: 9 named tests. \(outcome) Ready to commit."
            }
            return "Checks failed at \(job.result?.failingStep ?? "unknown step"). See failure below."
        } failure: { _ in "Read the failing step, adjust under a new candidate name, or inspect the retained evidence." }
    }

    @MainActor
    func commit() async {
        let name = candidateName
        let message = commitMessage.isEmpty
            ? "Candidate \(name): \(state.acceptedTitle.lowercased())"
            : commitMessage
        await runJob(op: "commit", nextName: name) { sid in
            try await self.client.commit(sid, candidate: name, message: message)
        } success: { job in
            "Committed \(String((job.result?.commit ?? "").prefix(12))) for candidate \(name). Push is a separate action."
        } failure: { _ in "Re-check under the accepted answer, then commit again. No commit was created." }
    }

    @MainActor
    func push() async {
        let name = candidateName
        await runJob(op: "push", nextName: name) { sid in
            try await self.client.push(sid, candidate: name)
        } success: { job in
            if job.result?.deduplicated == true {
                return "Remote already at this commit — deduplicated, no duplicate created."
            }
            return "Pushed \(String((job.result?.commit ?? "").prefix(12))). Observe its exact-head run."
        } failure: { _ in "The commit exists locally. Retry push — a retry never creates a duplicate commit." }
    }

    @MainActor
    func observe() async {
        guard let sid = sessionID else { return }
        guard let commit = state.candidates[candidateName]?.commit else {
            noteText("Nothing to observe: candidate \(candidateName) has no commit yet.",
                     action: "Commit first, then observe.")
            return
        }
        await runJob(op: "observe", nextName: candidateName) { _ in
            try await self.client.observe(sid, commit: commit)
        } success: { job in
            "Run \(job.result?.runID ?? 0): \(job.result?.conclusion ?? "unknown") for \(String(commit.prefix(12)))."
        } failure: { _ in "The run may still be queued — a self-hosted runner takes one job at a time. Observe again." }
    }

    @MainActor
    func loadDiff() async {
        guard let sid = sessionID else { return }
        let wanted = state.viewed
        guard let tree = state.candidates[wanted]?.tree else {
            diffText = "No candidate \(wanted) yet."
            diffLoadedFor = ""
            return
        }
        let requestID = UUID()
        diffRequestID = requestID
        do {
            let response = try await client.diff(sid, candidate: wanted)
            // Ignore the reply if the user traversed elsewhere while it
            // was in flight: stale text must never label a new node.
            guard sessionID == sid, wanted == state.viewed,
                  state.candidates[wanted]?.tree == tree,
                  diffRequestID == requestID, response.candidate == wanted else { return }
            diffText = response.diff.isEmpty ? "No differences from parent." : response.diff
            diffLoadedFor = wanted
        } catch {
            guard sessionID == sid, wanted == state.viewed,
                  state.candidates[wanted]?.tree == tree,
                  diffRequestID == requestID else { return }
            diffText = "Diff unavailable: \(error.localizedDescription)"
            diffLoadedFor = ""
        }
    }

    @MainActor
    func loadSource() async {
        guard let sid = sessionID else { return }
        let name = state.viewed
        let path = sourcePath
        let wanted = "\(name)|\(path)"
        guard let tree = state.candidates[name]?.tree else {
            sourceText = "No candidate \(name) yet."
            sourceLoadedFor = ""
            return
        }
        let requestID = UUID()
        sourceRequestID = requestID
        do {
            let response = try await client.source(sid, candidate: name, path: path)
            guard sessionID == sid, name == state.viewed, path == sourcePath,
                  state.candidates[name]?.tree == tree, sourceRequestID == requestID,
                  response.candidate == name, response.path == path else { return }
            sourceText = response.text
            sourceLoadedFor = wanted
        } catch {
            guard sessionID == sid, name == state.viewed, path == sourcePath,
                  state.candidates[name]?.tree == tree,
                  sourceRequestID == requestID else { return }
            sourceText = "Source unavailable: \(error.localizedDescription)"
            sourceLoadedFor = ""
        }
    }

    // MARK: - Plumbing

    private func resetPresentationForSession() {
        state = LiveState()
        repoCanonical = nil
        repoCommit = nil
        candidateName = "A"
        constructionJob = nil
        constructionIdentity = nil
        reservedCandidateNames = []
        sourceText = ""
        sourceLoadedFor = ""
        diffText = ""
        diffLoadedFor = ""
        sourcePath = "queued/worker.go"
        sourceRequestID = UUID()
        diffRequestID = UUID()
    }

    private func receiveConstruction(_ job: LiveCompanionClient.Job, sid: String) {
        guard sessionID == sid, let detail = job.construction,
              constructionIdentity?.matches(sessionID: sid, jobID: job.jobID,
                                             candidate: detail.candidate) == true else { return }
        constructionJob = job
    }

    struct JobFailed: Error {
        var job: LiveCompanionClient.Job
        var op: String
    }

    private func jobFailed(_ job: LiveCompanionClient.Job, _ op: String) -> JobFailed {
        JobFailed(job: job, op: op)
    }

    /// Cancel the currently running companion job, if any. The poll
    /// loop below observes the terminal cancelled state and reports it
    /// as a cancelled outcome; the last valid state is preserved.
    @MainActor
    func cancelActive() async {
        guard let sid = sessionID, let jid = activeJob?.jobID else { return }
        do {
            let reply = try await client.cancel(sid, jid)
            guard sessionID == sid, activeJob?.jobID == jid else { return }
            activeJob = reply
            receiveConstruction(reply, sid: sid)
        } catch {
            note(error, action: "The job keeps running. Cancel again or wait for it to finish.")
        }
    }

    @MainActor
    private func track(_ job: LiveCompanionClient.Job, op: String, sid: String) async throws -> LiveCompanionClient.Job {
        guard sessionID == sid else { throw CancellationError() }
        activeJob = job
        activeOp = op
        receiveConstruction(job, sid: sid)
        defer { if activeJob?.jobID == job.jobID { activeJob = nil } }
        // Poll here — not inside the client — so every poll publishes
        // the newest progress/note to the model instead of freezing at
        // the initial record. Cancellation flows through the same path.
        var current = job
        while !current.isTerminal {
            if let detail = current.construction, let revision = detail.intentRevision,
               state.acceptedRevision != revision || state.accepted != detail.answer {
                await refresh()
            }
            try await Task.sleep(for: .seconds(1))
            current = try await client.job(sid, job.jobID)
            guard sessionID == sid, current.jobID == job.jobID else { throw CancellationError() }
            activeJob = current
            receiveConstruction(current, sid: sid)
        }
        return current
    }

    @MainActor
    private func runJob(op: String, nextName: String,
                        start: (String) async throws -> LiveCompanionClient.Job,
                        success: (LiveCompanionClient.Job) -> String,
                        failure: (LiveCompanionClient.Job) -> String) async {
        guard let sid = sessionID else {
            noteText("Not connected.", action: "Tap Connect first.")
            return
        }
        guard !busy else { return }
        if let operation = LiveOperation(rawValue: op),
           state.operationSucceeded(operation, for: nextName) { return }
        isSubmitting = true
        activeOp = op
        defer { isSubmitting = false }
        lastError = nil
        lastNextAction = nil
        lastResult = nil
        do {
            let job = try await start(sid)
            let done = try await track(job, op: op, sid: sid)
            await refresh()
            if done.status == "succeeded" {
                // A check job can succeed with a FAILED verdict: surface
                // the outcome line, plus failure + next action.
                if op == "check", done.result?.passed == false {
                    lastError = "Check failed at \(done.result?.failingStep ?? "unknown step")"
                    lastNextAction = failure(done)
                    lastResult = nil
                } else {
                    lastResult = success(done)
                }
            } else {
                throw jobFailed(done, op)
            }
        } catch let failed as JobFailed {
            await refresh()
            if failed.job.status == "cancelled" {
                lastError = "\(op) cancelled by operator."
                lastNextAction = "Cancelled cleanly. The last valid state is preserved — retry when ready."
                return
            }
            let detail = failed.job.error ?? "job \(failed.job.status)"
            lastError = "\(op) \(failed.job.status): \(detail)"
            lastNextAction = failure(failed.job)
        } catch {
            await refresh()
            note(error, action: failure(
                LiveCompanionClient.Job(jobID: "", op: op, status: "failed",
                                        progress: 0, result: nil, error: nil)))
        }
    }

    @MainActor
    private func note(_ error: Error, action: String) {
        if let failed = error as? JobFailed {
            lastError = "\(failed.op) \(failed.job.status): \(failed.job.error ?? "see job")"
        } else {
            lastError = error.localizedDescription
        }
        lastNextAction = action
    }

    @MainActor
    private func noteText(_ message: String, action: String) {
        lastError = message
        lastNextAction = action
    }
}
