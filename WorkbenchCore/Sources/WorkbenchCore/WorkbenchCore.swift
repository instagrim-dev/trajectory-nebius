/// Pure decision state for the Trajectory Workbench scaffold.
///
/// Triple-distinct semantics, mirroring the workbench's
/// `selected_node` / `accepted_answer` / `view_answer` split:
/// - Selected: tree cursor; preview/accept target. Never accepts by itself.
/// - Accepted: owner intent; newly bound reports bind against it.
/// - Viewed: program whose source/evidence is shown; reopening one never
///   changes the latest accepted intent.
///
/// Report applicability (`ReportBinding`) is derived from the shared
/// viewed program + latest accepted intent and is independent of the
/// check outcome (pass/fail/incomplete).

/// The consequential owner question has two authored answers.
public enum Answer: String, CaseIterable, Sendable, Hashable {
    case queueTime
    case deliveryTime

    public var title: String {
        switch self {
        case .queueTime: "Request-time authorization governs"
        case .deliveryTime: "Delivery-time authorization governs"
        }
    }
}

/// Saved sample programs. v1 was built under the queue-time answer,
/// v2 under the delivery-time answer.
public enum SampleProgram: String, CaseIterable, Sendable, Hashable {
    case v1
    case v2

    public var answer: Answer {
        switch self {
        case .v1: .queueTime
        case .v2: .deliveryTime
        }
    }

    public var versionLabel: String {
        switch self {
        case .v1: "v1 · request-time"
        case .v2: "v2 · delivery-time"
        }
    }

    /// Retained 12-character source identity prefix from the captured fixture.
    public var sourceIdentityPrefix: String {
        switch self {
        case .v1: "76426ef75011"
        case .v2: "61885a86f762"
        }
    }
}

/// Outcome of a retained (previously captured) check observation.
/// Displayed separately from applicability; never implies it.
public enum CheckOutcome: String, Sendable, Hashable {
    case passed
    case failed
    case incomplete
}

/// A retained check observation bound to the program it was captured for.
/// Nothing here executes checks; observations are fixture data.
public struct RetainedCheck: Sendable, Hashable {
    public var id: String
    public var program: SampleProgram
    public var outcome: CheckOutcome

    public init(id: String, program: SampleProgram, outcome: CheckOutcome) {
        self.id = id
        self.program = program
        self.outcome = outcome
    }
}

/// How a retained observation applies to what is currently viewed,
/// given the latest accepted intent. Orthogonal to pass/fail/incomplete.
public enum ReportBinding: String, Sendable, Hashable {
    /// No retained observation exists for the viewed program.
    case unchecked
    /// Viewed program matches the latest accepted intent and a retained
    /// check exists for it.
    case current
    /// Retained check is valid for the saved branch only; the latest
    /// accepted intent points elsewhere.
    case historical
    /// Retained check no longer matches source/contract/environment;
    /// it verifies nothing.
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

public struct WorkbenchState: Sendable, Hashable {
    public var selected: Answer
    public var accepted: Answer
    public var viewed: SampleProgram
    public var retainedChecks: [RetainedCheck]
    /// Set when source, contract, or environment changed since capture.
    public var sourceChanged: Bool

    public init(
        selected: Answer,
        accepted: Answer,
        viewed: SampleProgram,
        retainedChecks: [RetainedCheck] = [],
        sourceChanged: Bool = false
    ) {
        self.selected = selected
        self.accepted = accepted
        self.viewed = viewed
        self.retainedChecks = retainedChecks
        self.sourceChanged = sourceChanged
    }

    /// Accept is enabled only when the selected answer differs from
    /// the accepted one.
    public var isAcceptEnabled: Bool { selected != accepted }

    /// Move the cursor. Never changes accepted intent.
    public mutating func select(_ answer: Answer) {
        selected = answer
    }

    /// Adopt the selected answer as owner intent.
    /// - Returns: Whether anything changed (false when already accepted).
    @discardableResult
    public mutating func accept() -> Bool {
        guard selected != accepted else { return false }
        accepted = selected
        return true
    }

    /// Reopen a saved program for viewing. Changes viewed only;
    /// accepted intent and selection are untouched.
    public mutating func openProgram(_ program: SampleProgram) {
        viewed = program
    }

    /// Retained observation for the viewed program, if any.
    public var viewedCheck: RetainedCheck? {
        retainedChecks.first { $0.program == viewed }
    }

    /// The one true binding for what is viewed today, derived from the
    /// shared viewed program + latest accepted intent. Pass/fail is a
    /// separate line and never changes this value.
    public var reportBinding: ReportBinding {
        guard viewedCheck != nil else { return .unchecked }
        if sourceChanged { return .mismatched }
        if viewed.answer == accepted { return .current }
        return .historical
    }
}
