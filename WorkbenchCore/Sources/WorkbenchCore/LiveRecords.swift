import Foundation

/// Durable live records for connected-repository mode.
///
/// These mirror the companion's session state (see Companion/server.py)
/// without importing it: every identity below is produced by the
/// companion/GitHub, never hand-set by the UI. Report binding is derived
/// from actual content identity (candidate tree + verified tree + accepted
/// answer), never from a manual "source changed" flag. Retained sample
/// fixture hashes are never valid here: live candidates carry commit SHAs
/// and tree hashes from the real demo repository.
///
/// Nothing here performs networking; `LiveCompanionClient` (in the app
/// target) moves these records over host-local HTTP.
public enum LiveAnswer: String, CaseIterable, Sendable, Hashable, Codable {
    case queueTime = "queue_time"
    case deliveryTime = "delivery_time"

    public var title: String {
        switch self {
        case .queueTime: "Request-time authorization governs"
        case .deliveryTime: "Delivery-time authorization governs"
        }
    }

    public var shortTitle: String {
        self == .queueTime ? "Request time" : "Delivery time"
    }

    public var candidatePrefix: String { self == .queueTime ? "A" : "B" }
}

public struct LiveHistoryNode: Sendable, Hashable {
    public let name: String
    public let depth: Int
}

/// A live candidate revision: generated source descended from a parent
/// commit under one accepted intent revision.
public struct LiveCandidate: Sendable, Hashable, Codable {
    public var name: String
    public var answer: LiveAnswer
    public var intentRevision: Int
    public var sourceParent: String
    public var tree: String
    public var changedFiles: [String]
    public var commit: String?
    public var parentCandidate: String?
    public var parentTree: String?
    public var baseGitCommit: String?
    public var status: String?
    public var generator: LiveGeneratorProvenance?
    public var generatedAt: String?

    public init(name: String, answer: LiveAnswer, intentRevision: Int,
                sourceParent: String, tree: String,
                changedFiles: [String] = [], commit: String? = nil,
                parentCandidate: String? = nil, parentTree: String? = nil,
                baseGitCommit: String? = nil, status: String? = nil,
                generator: LiveGeneratorProvenance? = nil,
                generatedAt: String? = nil) {
        self.name = name
        self.answer = answer
        self.intentRevision = intentRevision
        self.sourceParent = sourceParent
        self.tree = tree
        self.changedFiles = changedFiles
        self.commit = commit
        self.parentCandidate = parentCandidate
        self.parentTree = parentTree
        self.baseGitCommit = baseGitCommit
        self.status = status
        self.generator = generator
        self.generatedAt = generatedAt
    }
}

/// A verification bound to one exact candidate tree, intent revision,
/// checker identity, and observed outcome.
public struct LiveVerification: Sendable, Hashable, Codable {
    public var candidate: String
    public var tree: String
    public var intentRevision: Int
    public var checkerID: String
    public var passed: Bool
    public var failingStep: String?
    public var testsPassed: [String]
    public var scenarioStatus: String?

    public init(candidate: String, tree: String, intentRevision: Int,
                checkerID: String, passed: Bool, failingStep: String? = nil,
                testsPassed: [String] = [], scenarioStatus: String? = nil) {
        self.candidate = candidate
        self.tree = tree
        self.intentRevision = intentRevision
        self.checkerID = checkerID
        self.passed = passed
        self.failingStep = failingStep
        self.testsPassed = testsPassed
        self.scenarioStatus = scenarioStatus
    }
}

/// A real commit with its parent, plus the separate push outcome.
public struct LiveCommit: Sendable, Hashable, Codable {
    public var candidate: String
    public var commit: String
    public var parent: String
    public var message: String
    public var pushed: Bool
    public var deduplicatedPush: Bool

    public init(candidate: String, commit: String, parent: String,
                message: String, pushed: Bool = false,
                deduplicatedPush: Bool = false) {
        self.candidate = candidate
        self.commit = commit
        self.parent = parent
        self.message = message
        self.pushed = pushed
        self.deduplicatedPush = deduplicatedPush
    }
}

/// A GitHub Actions run observed for one exact head commit.
public struct LiveRun: Sendable, Hashable, Codable {
    public var commit: String
    public var runID: Int64
    public var attempt: Int
    public var conclusion: String?
    public var url: String

    public init(commit: String, runID: Int64, attempt: Int,
                conclusion: String? = nil, url: String = "") {
        self.commit = commit
        self.runID = runID
        self.attempt = attempt
        self.conclusion = conclusion
        self.url = url
    }
}

/// How a live verification applies to what is viewed, derived from shared
/// viewed candidate + latest accepted intent + content identity.
/// Orthogonal to pass/fail and to CI conclusions.
public enum LiveBinding: String, Sendable, Hashable {
    /// No verification exists for the viewed candidate's current tree.
    case unchecked
    /// Viewed candidate matches the latest accepted intent and a passing
    /// verification exists for its exact current tree.
    case current
    /// A passing verification exists, but only for a tree or intent the
    /// latest accepted answer no longer points at.
    case historical
    /// The candidate tree no longer equals the verified tree (or the
    /// verification failed): it verifies nothing.
    case mismatched

    public var title: String {
        switch self {
        case .unchecked: "Not checked"
        case .current: "Current"
        case .historical: "Historical"
        case .mismatched: "Not applicable"
        }
    }
}

public struct LiveState: Sendable, Hashable {
    public var selected: LiveAnswer
    public var accepted: LiveAnswer?
    public var acceptedRevision: Int
    public var viewed: String
    public var candidates: [String: LiveCandidate]
    public var verifications: [LiveVerification]
    public var commits: [LiveCommit]
    public var runs: [LiveRun]
    public var attemptedCandidateNames: Set<String>

    public init(selected: LiveAnswer = .queueTime,
                accepted: LiveAnswer? = nil,
                acceptedRevision: Int? = nil,
                viewed: String = "A",
                candidates: [String: LiveCandidate] = [:],
                verifications: [LiveVerification] = [],
                commits: [LiveCommit] = [],
                runs: [LiveRun] = [],
                attemptedCandidateNames: Set<String> = []) {
        self.selected = selected
        self.accepted = accepted
        self.acceptedRevision = accepted == nil ? -1 : (acceptedRevision ?? 0)
        self.viewed = viewed
        self.candidates = candidates
        self.verifications = verifications
        self.commits = commits
        self.runs = runs
        self.attemptedCandidateNames = attemptedCandidateNames
    }

    public var isAcceptEnabled: Bool { selected != accepted }

    public var acceptedTitle: String { accepted?.title ?? "No answer accepted yet" }

    /// Never reuse a retained identity. Pending attempts can be reserved by
    /// the caller before the first network suspension to prevent double taps.
    public func nextCandidateName(for answer: LiveAnswer,
                                  reserving names: Set<String> = []) -> String {
        let used = Set(candidates.keys).union(attemptedCandidateNames).union(names)
        let prefix = answer.candidatePrefix
        if !used.contains(prefix) { return prefix }
        var suffix = 2
        while used.contains("\(prefix)-\(suffix)") { suffix += 1 }
        return "\(prefix)-\(suffix)"
    }

    /// A navigation convenience, not artifact acceptance. Multiple retained
    /// candidates can implement the currently accepted rule.
    public var latestCandidateMatchingAccepted: String? {
        guard let accepted else { return nil }
        return candidates.values.filter { $0.answer == accepted }.sorted {
            if $0.intentRevision != $1.intentRevision {
                return $0.intentRevision < $1.intentRevision
            }
            if $0.generatedAt != $1.generatedAt {
                return ($0.generatedAt ?? "") < ($1.generatedAt ?? "")
            }
            return $0.name.compare($1.name, options: .numeric) == .orderedAscending
        }.last?.name
    }

    /// Move the cursor. Never changes accepted intent.
    public mutating func select(_ answer: LiveAnswer) {
        selected = answer
    }

    /// Adopt the selected answer as owner intent. Intent only: no
    /// generation, check, commit, or push happens here.
    @discardableResult
    public mutating func accept() -> Bool {
        guard selected != accepted else { return false }
        accepted = selected
        acceptedRevision += 1
        return true
    }

    /// Reopen a saved candidate for viewing. Read-only: changes viewed
    /// only; accepted intent and evidence are untouched, and nothing is
    /// regenerated, rechecked, or recommitted.
    public mutating func openCandidate(_ name: String) {
        viewed = name
    }

    /// Latest passing verification for the viewed candidate's exact
    /// current tree, if any.
    public var viewedPass: LiveVerification? {
        guard let cand = candidates[viewed] else { return nil }
        return verifications.last {
            $0.candidate == viewed && $0.tree == cand.tree && $0.passed
        }
    }

    /// Any verification (passing or not) for the viewed candidate's
    /// exact current tree AND intended revision. Applicability is
    /// orthogonal to pass/fail: a failed check on this tree is still
    /// the current evidence, with its failure shown as the outcome.
    public var viewedVerificationForTree: LiveVerification? {
        guard let cand = candidates[viewed] else { return nil }
        return verifications.last {
            $0.candidate == viewed && $0.tree == cand.tree
                && $0.intentRevision == cand.intentRevision
        }
    }

    public var binding: LiveBinding {
        guard let cand = candidates[viewed] else { return .unchecked }
        if viewedVerificationForTree != nil {
            return cand.answer == accepted ? .current : .historical
        }
        // Verified before, but the tree or intended revision moved
        // since: stale evidence is mismatched, derived from identities
        // rather than a hand-set flag.
        let everVerified = verifications.contains { $0.candidate == viewed }
        return everVerified ? .mismatched : .unchecked
    }

    /// Name of the candidate whose commit is this candidate's source
    /// parent, or nil when it descends directly from the imported
    /// baseline. Browsing history is read-only: this only reads
    /// recorded commit identities, never mutable repository state.
    public func parentCandidate(for name: String) -> String? {
        guard let record = candidates[name] else { return nil }
        if let parent = record.parentCandidate {
            guard parent != name, let retained = candidates[parent],
                  record.parentTree == retained.tree else { return nil }
            return parent
        }
        for (other, candidate) in candidates where other != name {
            if candidate.commit == record.sourceParent { return other }
        }
        return nil
    }

    /// Parent-first traversal; incomplete or cyclic ancestry remains visible.
    public var historyOrder: [LiveHistoryNode] {
        let names = candidates.keys.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        var children: [String: [String]] = [:]
        var roots: [String] = []
        for name in names {
            if let parent = parentCandidate(for: name) {
                children[parent, default: []].append(name)
            } else {
                roots.append(name)
            }
        }
        var seen = Set<String>()
        var result: [LiveHistoryNode] = []
        func visit(_ name: String, depth: Int) {
            guard seen.insert(name).inserted else { return }
            result.append(LiveHistoryNode(name: name, depth: depth))
            for child in children[name, default: []] { visit(child, depth: depth + 1) }
        }
        for name in roots { visit(name, depth: 0) }
        for name in names { visit(name, depth: 0) }
        return result
    }

    /// Immutable ancestry label for the decision map: the candidate's
    /// own recorded source parent. This never follows the mutable
    /// current repository head — after B lands, A's baseline still
    /// reads the imported parent, not B's commit.
    public func mapBaseline(for name: String) -> String? {
        guard let record = candidates[name] else { return nil }
        guard record.parentCandidate == nil else { return nil }
        guard parentCandidate(for: name) == nil else { return nil }
        return String(record.sourceParent.prefix(12))
    }

    /// Plain-language consequence of the viewed candidate's applicable
    /// check, bound to the observed scenario outcome — never to an
    /// expected answer or a canned fixture claim. Missing, failed, or
    /// mismatched evidence yields no release/block statement.
    public var viewedConsequence: String? {
        guard let verified = viewedVerificationForTree, verified.passed else {
            return nil
        }
        switch verified.scenarioStatus {
        case "exported":
            return "Access was revoked while queued. The customer records package was still released."
        case "access_revoked":
            return "Access was revoked while queued. Delivery was blocked; nothing was released."
        default:
            return nil
        }
    }

    /// Compact accepted/viewed context for the evidence viewport:
    /// "Accepted: delivery-time · Viewing: A (historical)".
    public var contextLine: String {
        let acceptedSlug = accepted == .queueTime ? "request-time" : (accepted == .deliveryTime ? "delivery-time" : "none")
        return "Accepted: \(acceptedSlug) · Viewing: \(viewed) (\(binding.title.lowercased()))"
    }

    /// Commit bound to the viewed candidate, if one exists.
    public var viewedCommit: LiveCommit? {
        commits.last { $0.candidate == viewed }
    }

    /// CI run bound to the viewed candidate's exact commit, if observed.
    public var viewedRun: LiveRun? {
        guard let commit = candidates[viewed]?.commit else { return nil }
        return runs.last { $0.commit == commit }
    }
}

/// Compact decisive authorization guard excerpted from fetched
/// `worker.go` source text — the returned lines are a slice of the
/// supplied source, never synthesized illustrative code. Locates the
/// first negated authorization check (`if !…`) with one line of
/// context on each side, so the changed guard reads without
/// horizontal panning while the full source stays inspectable.
public func decisiveGuardExcerpt(sourceText: String) -> String? {
    let lines = sourceText.components(separatedBy: "\n")
    guard let index = lines.firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces).hasPrefix("if !")
    }) else {
        return nil
    }
    let lower = max(0, index - 1)
    let upper = min(lines.count - 1, index + 1)
    let excerpt = lines[lower...upper].joined(separator: "\n")
    return excerpt.isEmpty ? nil : excerpt
}
