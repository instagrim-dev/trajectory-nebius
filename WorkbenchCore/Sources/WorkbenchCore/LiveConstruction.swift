import Foundation

/// Optional on older retained candidates. These values are receipt fields,
/// never guessed from the answer, a model name, or a current configuration.
public struct LiveGeneratorProvenance: Sendable, Hashable, Codable {
    public var provider: String?
    public var tool: String?
    public var model: String?
    public var sessionID: String?
    public var exitCode: Int?

    enum CodingKeys: String, CodingKey {
        case provider, tool, model
        case sessionID = "session_id"
        case exitCode = "exit_code"
    }
}

/// A source snapshot observed by the companion while this exact job runs.
/// Provisional bytes are never a candidate or a passing verification.
public struct LiveConstructionFile: Sendable, Hashable, Codable, Identifiable {
    public var path: String
    public var before: String
    public var after: String
    public var diff: String
    public var sha256: String

    public var id: String { path }
    public var changed: Bool { before != after }
}

/// Only observable operation facts are transported. No raw agent reasoning
/// or invented typing schedule is part of this contract.
public struct LiveConstructionEvent: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var at: String
    public var kind: String
    public var message: String
}

public struct LiveConstruction: Sendable, Hashable, Codable {
    public var candidate: String
    public var answer: LiveAnswer
    public var intentRevision: Int?
    public var sourceParent: String?
    public var parentCandidate: String?
    public var parentTree: String?
    public var provider: String
    public var agent: String
    public var model: String
    public var generatorSessionID: String?
    public var stage: String
    public var files: [LiveConstructionFile]
    public var events: [LiveConstructionEvent]
    public var outputTree: String?
    public var changedPaths: [String]?
    public var provisional: Bool
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case candidate, answer, provider, agent, model, stage, files, events
        case provisional, error
        case intentRevision = "intent_revision"
        case sourceParent = "source_parent"
        case parentCandidate = "parent_candidate"
        case parentTree = "parent_tree"
        case generatorSessionID = "generator_session_id"
        case outputTree = "output_tree"
        case changedPaths = "changed_paths"
    }

    public var changedFiles: [LiveConstructionFile] { files.filter(\.changed) }

    /// Completion is an observed construction result, never a check verdict.
    public var hasPublishedCandidate: Bool {
        stage == "succeeded" && !provisional && !(outputTree ?? "").isEmpty
    }
}

/// The view cursor may move freely while a run continues. Only updates bound
/// to the originally submitted session, job, and candidate can replace it.
public struct LiveConstructionIdentity: Sendable, Hashable {
    public var sessionID: String
    public var jobID: String
    public var candidate: String

    public init(sessionID: String, jobID: String, candidate: String) {
        self.sessionID = sessionID
        self.jobID = jobID
        self.candidate = candidate
    }

    public func matches(sessionID: String, jobID: String,
                        candidate: String) -> Bool {
        self.sessionID == sessionID && self.jobID == jobID
            && self.candidate == candidate
    }
}
