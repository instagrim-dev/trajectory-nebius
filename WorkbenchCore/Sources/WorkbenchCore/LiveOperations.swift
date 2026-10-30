import Foundation

public enum LiveOperation: String, Sendable {
    case check, commit, push, observe
}

public enum LiveCheckSummary: Sendable, Equatable {
    case notChecked, passed, failed, stale

    public var title: String {
        switch self {
        case .notChecked: "Not checked"
        case .passed: "Checks passed"
        case .failed: "Check failed"
        case .stale: "Check out of date"
        }
    }
}

extension LiveState {
    /// A candidate's newest applicable result; other candidates' checks never apply.
    public func checkSummary(for name: String) -> LiveCheckSummary {
        guard let candidate = candidates[name] else { return .notChecked }
        if let verification = verifications.last(where: {
            $0.candidate == name && $0.tree == candidate.tree
                && $0.intentRevision == candidate.intentRevision
        }) {
            return verification.passed ? .passed : .failed
        }
        return verifications.contains(where: { $0.candidate == name }) ? .stale : .notChecked
    }
    /// Success belongs to the exact saved artifact, including after resume or traversal.
    public func operationSucceeded(_ operation: LiveOperation, for name: String) -> Bool {
        guard let record = candidates[name] else { return false }
        switch operation {
        case .check:
            return verifications.last {
                $0.candidate == name && $0.tree == record.tree
                    && $0.intentRevision == record.intentRevision
            }?.passed == true
        case .commit:
            return record.commit != nil
        case .push:
            guard let commit = record.commit else { return false }
            return commits.last { $0.candidate == name && $0.commit == commit }?.pushed == true
        case .observe:
            guard let commit = record.commit else { return false }
            return runs.last { $0.commit == commit }?.conclusion == "success"
        }
    }
}

/// Backend receipt vocabulary is preserved; only the presentation changes.
public func liveConstructionStageTitle(_ stage: String) -> String {
    stage == "invoking" ? "synthesizing" : stage
}
