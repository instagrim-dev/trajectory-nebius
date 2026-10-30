import Foundation
import Observation
import WorkbenchCore

/// One shared in-memory state for the whole scaffold, so selection,
/// acceptance, and the viewed program stay consistent across screens.
/// All data below is authored sample content: queue-time and
/// delivery-time answers, two saved sample programs, and retained
/// fixture observations. Nothing constructs programs or runs checks.
@Observable
final class WorkbenchModel {
    /// Connected-repository state. Separate from sample state: the Live
    /// tab drives the loopback companion; sample screens never do.
    var live = LiveWorkbenchModel()

    var state = WorkbenchState(
        selected: .queueTime,
        accepted: .deliveryTime,
        viewed: .v1,
        retainedChecks: [
            RetainedCheck(id: "check-001", program: .v1, outcome: .passed),
            RetainedCheck(id: "check-002", program: .v2, outcome: .passed),
        ]
    )

    var showingPreview = false
    var showingCompare = false
    var showingAbout = false

    // MARK: - Intents (all local; nothing leaves the device)

    func select(_ answer: Answer) { state.select(answer) }

    func accept() { state.accept() }

    /// Cheap reopen: viewing a saved program never changes accepted intent.
    func openProgram(_ program: SampleProgram) { state.openProgram(program) }

    // MARK: - Sample content

    let requestSummary = "A privacy analyst queues a customer records package for a CCPA access request."
    let ownerQuestion = "When should staff access be checked: when the records request is received and processed, or when the package is retrieved and delivered?"
    let transcript = [
        "Owner: The customer’s request stays active, but the analyst’s access is revoked before delivery.",
        "Owner: Should the saved request-time permission or current delivery-time access govern release?",
    ]

    func scope(for answer: Answer) -> String {
        switch answer {
        case .queueTime:
            "Use the staff access permission captured when the records request was processed."
        case .deliveryTime:
            "Check current staff access when the records package is retrieved and delivered."
        }
    }

    private let fixture = FixtureCatalog.shared

    let previewCases = [
        "Finite fixture: three Go sources per program (domain.go, queue.go, worker.go).",
        "Request-time to delivery-time revision: queue.go + worker.go changed, domain.go byte-identical.",
        "Saved target: reopen only, no new files.",
    ]

    /// The actual nine retained check names. Zero are executed here.
    var requiredChecks: [String] { fixture.checkNames }

    struct FileSample {
        var name: String
        var v1Note: String
        var v2Note: String
        var v1Excerpt: String
        var v2Excerpt: String
        var diff: String?
    }

    /// Real notes, excerpts, and directional diffs bound to the bundled
    /// retained-fixture bytes (see FixtureCatalog; bound by FixtureTests).
    /// There is no credential refresh anywhere in the fixture.
    var files: [FileSample] {
        ["queue.go", "worker.go", "domain.go"].map { name in
            FileSample(
                name: name,
                v1Note: fixture.note(program: .v1, file: name),
                v2Note: fixture.note(program: .v2, file: name),
                v1Excerpt: fixture.excerpt(program: .v1, file: name),
                v2Excerpt: fixture.excerpt(program: .v2, file: name),
                diff: fixture.diff(file: name)
            )
        }
    }

    func observationLine(for program: SampleProgram) -> String {
        if let check = fixture.check(for: program) {
            return "Retained \(check.id) · \(check.status) · \(check.passedCount)/\(check.tests.count) tests pass (captured fixture observation)."
        }
        return "No retained observation — expected behavior only."
    }

    /// Tangible retained outcome both reports observed, e.g. v1 exported
    /// while v2 refused after access was revoked mid-queue.
    func scenarioLine(for program: SampleProgram) -> String {
        fixture.scenarioLine(for: program)
    }
}
