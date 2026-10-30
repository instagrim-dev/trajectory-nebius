import Foundation

/// Single data source for the retained finite fixture behind the sample.
///
/// Ground truth is bundled bytes, copied verbatim from the explicitly
/// authorized Trajectory evidence (never edited there or here):
/// - `Fixture/programs/v1/*.go` and `Fixture/programs/v2/*.go`
/// - `Fixture/checks.json`: concise metadata (binding hashes, statuses,
///   test names, per-case observations) derived from
///   `check-001.json`/`check-002.json` with the raw log output omitted.
///
/// Curated presentation strings (notes, excerpts, diffs) live here next to
/// the bytes so `FixtureTests` can bind every line to the real source.
/// Nothing here executes checks or constructs programs.
public struct FixtureCatalog: Sendable {
    /// `"v1/queue.go"` → UTF-8 source text, exactly as bundled.
    public var sources: [String: String]
    /// Retained check records, in bundle order (check-001, check-002).
    public var checks: [FixtureCheck]

    public struct FixtureCheck: Sendable, Hashable {
        public var id: String
        public var program: SampleProgram
        /// Full `source_hash` from the report binding, e.g. `76426ef7…`.
        public var sourceHash: String
        /// Report status, e.g. `observed_pass`.
        public var status: String
        /// Test name → `"pass"`, in bundle order.
        public var tests: [FixtureTest]
        public var observations: [FixtureObservation]

        public var passedCount: Int { tests.filter { $0.result == "pass" }.count }
    }

    public struct FixtureTest: Sendable, Hashable {
        public var name: String
        public var result: String
    }

    public struct FixtureObservation: Sendable, Hashable {
        public var name: String
        public var status: String
        public var eventKinds: [String]
    }

    // MARK: - Loading

    public static func load(bundle: Bundle? = nil) throws -> FixtureCatalog {
        let bundle = bundle ?? Bundle.module
        var sources: [String: String] = [:]
        for program in ["v1", "v2"] {
            for file in ["domain.go", "queue.go", "worker.go"] {
                guard let url = bundle.url(
                    forResource: file,
                    withExtension: nil,
                    subdirectory: "Fixture/programs/\(program)"
                ) else {
                    throw FixtureError.missing("Fixture/programs/\(program)/\(file)")
                }
                sources["\(program)/\(file)"] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        guard let checksURL = bundle.url(forResource: "checks", withExtension: "json", subdirectory: "Fixture") else {
            throw FixtureError.missing("Fixture/checks.json")
        }
        let decoded = try JSONDecoder().decode(ChecksFile.self, from: Data(contentsOf: checksURL))
        let checks = try decoded.checks.map { record -> FixtureCheck in
            let program: SampleProgram
            switch record.binding.owner_answer {
            case "queue_time": program = .v1
            case "delivery_time": program = .v2
            default: throw FixtureError.missing("owner_answer \(record.binding.owner_answer)")
            }
            return FixtureCheck(
                id: record.id,
                program: program,
                sourceHash: record.binding.source_hash,
                status: record.status,
                tests: record.tests.map { FixtureTest(name: $0.name, result: $0.result) },
                observations: record.observations.map {
                    FixtureObservation(name: $0.case, status: $0.status, eventKinds: $0.events.map(\.kind))
                }
            )
        }
        return FixtureCatalog(sources: sources, checks: checks)
    }

    /// Shared catalog for sample UI. The bundle is part of the build, so a
    /// missing resource is a programmer error, surfaced loudly rather than
    /// as silently invented content.
    public static let shared: FixtureCatalog = {
        do {
            return try load()
        } catch {
            fatalError("Retained fixture bundle is unreadable: \(error)")
        }
    }()

    // MARK: - Ground-truth accessors

    public func sourceText(program: SampleProgram, file: String) -> String {
        sources["\(program.rawValue)/\(file)"] ?? ""
    }

    /// Required check names from the retained reports (nine, all passing).
    public var checkNames: [String] {
        checks.first?.tests.map(\.name) ?? []
    }

    public func check(for program: SampleProgram) -> FixtureCheck? {
        checks.first { $0.program == program }
    }

    public func observation(named name: String, program: SampleProgram) -> FixtureObservation? {
        check(for: program)?.observations.first { $0.name == name }
    }

    // MARK: - Curated presentation (every line bound to bundled bytes by tests)

    public func note(program: SampleProgram, file: String) -> String {
        switch (program, file) {
        case (.v1, "queue.go"):
            "Mode queue_time. The job carries the PermissionSnapshot captured at enqueue."
        case (.v2, "queue.go"):
            "Mode delivery_time. The job carries no snapshot — nothing is trusted from enqueue."
        case (.v1, "worker.go"):
            "Deliver trusts the enqueue-time snapshot: revoked access still exports."
        case (.v2, "worker.go"):
            "Deliver re-checks access.Allowed(tenant, user) at send: revoked access is refused."
        case (_, "domain.go"):
            "Byte-identical in v1 and v2: request shape, live access lookup, audit-then-release completion."
        default:
            "Retained fixture source."
        }
    }

    /// Small readable excerpt. queue.go/worker.go ship in full (each under
    /// 20 short lines); domain.go shows its characterizing lines.
    public func excerpt(program: SampleProgram, file: String) -> String {
        switch file {
        case "queue.go", "worker.go":
            sourceText(program: program, file: file)
        case "domain.go":
            "func (a Access) Allowed(tenant, user string) bool { return a[tenant][user] }\nconst AuditEnabled = true"
        default:
            ""
        }
    }

    /// Directional v1 → v2 diff. `-` lines are substrings of the v1 bytes,
    /// `+` lines of the v2 bytes, ` ` context lines of both; domain.go is
    /// unchanged so it has no diff.
    public func diff(file: String) -> String? {
        switch file {
        case "queue.go":
            """
             package queued
            -const Mode = "queue_time"
            +const Mode = "delivery_time"
             type Job struct {
             \tRequestID, UserID, TenantID string
            -\tPermissionSnapshot        bool
             }
             func Enqueue(req Request, access Access) (Job, bool) {
             \treturn Job{
             \t\tRequestID: req.ID, UserID: req.UserID, TenantID: req.TenantID,
            -\t\tPermissionSnapshot: access.Allowed(req.TenantID, req.UserID),
             \t}, true
            """
        case "worker.go":
            """
             \tif actorTenant != job.TenantID {
             \t\treturn Outcome{Status: "denied", Events: []Event{}}
             \t}
            -if !job.PermissionSnapshot {
            +if !access.Allowed(job.TenantID, job.UserID) {
             \t\treturn Outcome{Status: "access_revoked", Events: []Event{}}
             \t}
            """
        default:
            nil
        }
    }

    /// The tangible retained scenario both reports observed.
    public func scenarioLine(for program: SampleProgram) -> String {
        guard let seen = observation(named: "revoked_after_enqueue", program: program) else {
            return "No retained revoked_after_enqueue observation."
        }
        let events = seen.eventKinds.isEmpty ? "no events" : seen.eventKinds.joined(separator: " + ")
        return "Retained revoked_after_enqueue → \(seen.status) (\(events))."
    }
}

public enum FixtureError: Error {
    case missing(String)
}

// MARK: - Decoding (matches the concise bundled checks.json)

private struct ChecksFile: Decodable {
    var checks: [CheckRecord]

    struct CheckRecord: Decodable {
        var id: String
        var binding: Binding
        var status: String
        var tests: [TestEntry]
        var observations: [ObservationEntry]

        struct Binding: Decodable {
            var source_hash: String
            var owner_answer: String
        }

        struct ObservationEntry: Decodable {
            var `case`: String
            var status: String
            var events: [EventEntry]

            struct EventEntry: Decodable {
                var kind: String
            }
        }

        struct TestEntry: Decodable {
            var name: String
            var result: String
        }
    }
}
