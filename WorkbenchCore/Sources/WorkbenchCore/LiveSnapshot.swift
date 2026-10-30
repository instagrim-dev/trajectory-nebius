import Foundation

/// Codable mirror of the companion's session snapshot
/// (`Companion/server.py`, `Store` record). Every identity below is
/// produced by the companion/GitHub and decoded here — never hand-set
/// by the UI. `LiveCompanionClient` (app target) moves these records;
/// this file only decodes them and maps them onto `LiveState`.
public struct LiveSessionSnapshot: Sendable, Hashable, Codable {
    public var sessionID: String
    public var acceptedAnswer: LiveAnswer?
    public var intentCount: Int
    public var repoCanonical: String?
    public var repoResolvedCommit: String?
    public var candidates: [String: LiveCandidateRecord]
    public var verifications: [LiveVerificationRecord]
    public var commits: [LiveCommitRecord]
    public var runs: [LiveRunRecord]
    public var attemptedCandidateNames: Set<String>

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case acceptedAnswer = "accepted_answer"
        case intents, repo, candidates, verifications, commits, runs, jobs, proposals
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try root.decode(String.self, forKey: .sessionID)
        acceptedAnswer = try root.decodeIfPresent(LiveAnswer.self, forKey: .acceptedAnswer)
        intentCount = (try root.decodeIfPresent([LiveIntentRecord].self, forKey: .intents) ?? []).count
        let repo = try root.decodeIfPresent(LiveRepoRecord.self, forKey: .repo)
        repoCanonical = repo?.canonical
        repoResolvedCommit = repo?.resolvedCommit
        candidates = try root.decodeIfPresent([String: LiveCandidateRecord].self, forKey: .candidates) ?? [:]
        verifications = try root.decodeIfPresent([LiveVerificationRecord].self, forKey: .verifications) ?? []
        commits = try root.decodeIfPresent([LiveCommitRecord].self, forKey: .commits) ?? []
        runs = try root.decodeIfPresent([LiveRunRecord].self, forKey: .runs) ?? []
        let jobs = try root.decodeIfPresent([String: LiveAttemptJobRecord].self, forKey: .jobs) ?? [:]
        let proposals = try root.decodeIfPresent([LiveAttemptCandidateRecord].self, forKey: .proposals) ?? []
        attemptedCandidateNames = Set(jobs.values.compactMap {
            $0.construction?.candidate ?? $0.params?.candidate
        }).union(proposals.compactMap(\.candidate))
    }

    public func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: CodingKeys.self)
        try root.encode(sessionID, forKey: .sessionID)
        try root.encodeIfPresent(acceptedAnswer, forKey: .acceptedAnswer)
    }
}

/// Failed and queued attempts reserve a name without becoming candidate
/// artifacts. These deliberately decode only identity from durable receipts.
private struct LiveAttemptCandidateRecord: Decodable {
    var candidate: String?
}

private struct LiveAttemptJobRecord: Decodable {
    var params: LiveAttemptCandidateRecord?
    var construction: LiveAttemptCandidateRecord?
}

public struct LiveIntentRecord: Sendable, Hashable, Codable {
    public var revision: Int
    public var answer: LiveAnswer
}

public struct LiveRepoRecord: Sendable, Hashable, Codable {
    public var canonical: String?
    public var resolvedCommit: String?

    enum CodingKeys: String, CodingKey {
        case canonical
        case resolvedCommit = "resolved_commit"
    }
}

public struct LiveCandidateRecord: Sendable, Hashable, Codable {
    public var name: String
    public var answer: LiveAnswer
    public var intentRevision: Int
    public var sourceParent: String
    public var tree: String
    public var changed: [String]
    public var commit: String?
    public var status: String
    public var parentCandidate: String?
    public var parentTree: String?
    public var baseGitCommit: String?
    public var generator: LiveGeneratorProvenance?
    public var generatedAt: String?

    enum CodingKeys: String, CodingKey {
        case name = "candidate"
        case answer
        case intentRevision = "intent_revision"
        case sourceParent = "source_parent"
        case parentCandidate = "parent_candidate"
        case parentTree = "parent_tree"
        case baseGitCommit = "base_git_commit"
        case generatedAt = "generated_at"
        case generator
        case tree, changed, commit, status
    }

    public var liveCandidate: LiveCandidate {
        LiveCandidate(name: name, answer: answer, intentRevision: intentRevision,
                      sourceParent: sourceParent, tree: tree,
                      changedFiles: changed, commit: commit,
                      parentCandidate: parentCandidate, parentTree: parentTree,
                      baseGitCommit: baseGitCommit, status: status,
                      generator: generator, generatedAt: generatedAt)
    }
}

public struct LiveCheckerRecord: Sendable, Hashable, Codable {
    public var id: String
}

public struct LiveVerificationRecord: Sendable, Hashable, Codable {
    public var candidate: String
    public var tree: String
    public var intentRevision: Int
    public var checker: LiveCheckerRecord
    public var passed: Bool
    public var failingStep: String?
    public var testsPassed: [String]
    public var scenarioStatus: String?

    enum CodingKeys: String, CodingKey {
        case candidate, tree
        case intentRevision = "intent_revision"
        case checker, passed
        case failingStep = "failing_step"
        case testsPassed = "tests_passed"
        case scenarioStatus = "scenario_status"
    }

    public var liveVerification: LiveVerification {
        LiveVerification(candidate: candidate, tree: tree,
                         intentRevision: intentRevision,
                         checkerID: checker.id, passed: passed,
                         failingStep: failingStep, testsPassed: testsPassed,
                         scenarioStatus: scenarioStatus)
    }
}

public struct LivePushRecord: Sendable, Hashable, Codable {
    public var pushed: Bool
    public var deduplicated: Bool
}

public struct LiveCommitRecord: Sendable, Hashable, Codable {
    public var candidate: String
    public var commit: String
    public var parent: String
    public var message: String
    public var push: LivePushRecord?

    public var liveCommit: LiveCommit {
        LiveCommit(candidate: candidate, commit: commit, parent: parent,
                   message: message, pushed: push?.pushed ?? false,
                   deduplicatedPush: push?.deduplicated ?? false)
    }
}

public struct LiveRunRecord: Sendable, Hashable, Codable {
    public var commit: String
    public var runID: Int64
    public var attempt: Int
    public var conclusion: String?
    public var url: String

    enum CodingKeys: String, CodingKey {
        case commit
        case runID = "run_id"
        case attempt, conclusion, url
    }

    public var liveRun: LiveRun {
        LiveRun(commit: commit, runID: runID, attempt: attempt,
                conclusion: conclusion, url: url)
    }
}

extension LiveState {
    /// Map a decoded companion snapshot onto live UI state, preserving
    /// the local selection cursor and viewed candidate across refreshes.
    public static func fromSnapshot(_ snapshot: LiveSessionSnapshot,
                                    selected: LiveAnswer = .queueTime,
                                    viewed: String = "A") -> LiveState {
        var state = LiveState(
            selected: selected,
            accepted: snapshot.acceptedAnswer,
            acceptedRevision: snapshot.intentCount - 1,
            viewed: viewed,
            candidates: Dictionary(uniqueKeysWithValues: snapshot.candidates.map {
                ($0.key, $0.value.liveCandidate)
            }),
            verifications: snapshot.verifications.map(\.liveVerification),
            commits: snapshot.commits.map(\.liveCommit),
            runs: snapshot.runs.map(\.liveRun),
            attemptedCandidateNames: snapshot.attemptedCandidateNames)
        if state.candidates[state.viewed] == nil,
           let first = state.candidates.keys.sorted().first {
            state.viewed = first
        }
        return state
    }
}
