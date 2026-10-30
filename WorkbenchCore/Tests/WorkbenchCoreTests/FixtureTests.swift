import Testing
@testable import WorkbenchCore

/// Binds every curated sample string to the bundled retained-fixture bytes.
/// These tests fail if a note, excerpt, diff, check name, or identity drifts
/// from the actual copied fixture — the sample can never silently borrow a
/// real record for invented code again.
struct FixtureTests {
    private func catalog() throws -> FixtureCatalog {
        try FixtureCatalog.load()
    }

    @Test("bundled Go sources are non-empty for both programs")
    func sourcesPresent() throws {
        let catalog = try catalog()
        for program in SampleProgram.allCases {
            for file in ["domain.go", "queue.go", "worker.go"] {
                #expect(!catalog.sourceText(program: program, file: file).isEmpty)
            }
        }
    }

    @Test("v1 is queue-time with a permission snapshot; v2 is delivery-time without one")
    func modeAndSnapshot() throws {
        let catalog = try catalog()
        let v1Queue = catalog.sourceText(program: .v1, file: "queue.go")
        let v2Queue = catalog.sourceText(program: .v2, file: "queue.go")
        #expect(v1Queue.contains("Mode = \"queue_time\""))
        #expect(v1Queue.contains("PermissionSnapshot"))
        #expect(v2Queue.contains("Mode = \"delivery_time\""))
        #expect(!v2Queue.contains("PermissionSnapshot"))
    }

    @Test("v1 worker trusts the snapshot; v2 worker re-checks live access; no credential refresh exists")
    func workerGate() throws {
        let catalog = try catalog()
        let v1Worker = catalog.sourceText(program: .v1, file: "worker.go")
        let v2Worker = catalog.sourceText(program: .v2, file: "worker.go")
        #expect(v1Worker.contains("job.PermissionSnapshot"))
        #expect(v2Worker.contains("access.Allowed(job.TenantID, job.UserID)"))
        for program in SampleProgram.allCases {
            for file in ["domain.go", "queue.go", "worker.go"] {
                let text = catalog.sourceText(program: program, file: file).lowercased()
                #expect(!text.contains("refresh"))
                #expect(!text.contains("credential"))
            }
        }
    }

    @Test("domain.go is byte-identical across the revision")
    func domainUnchanged() throws {
        let catalog = try catalog()
        #expect(catalog.sourceText(program: .v1, file: "domain.go") == catalog.sourceText(program: .v2, file: "domain.go"))
        #expect(catalog.diff(file: "domain.go") == nil)
    }

    @Test("every curated diff line is a substring of the real version bytes")
    func diffsBoundToBytes() throws {
        let catalog = try catalog()
        for file in ["queue.go", "worker.go"] {
            let diff = try #require(catalog.diff(file: file))
            #expect(!diff.isEmpty)
            for line in diff.split(separator: "\n", omittingEmptySubsequences: true) {
                let marker = line.first
                let text = String(line.dropFirst())
                switch marker {
                case "-": #expect(catalog.sourceText(program: .v1, file: file).contains(text), "v1 \(file) lacks: \(text)")
                case "+": #expect(catalog.sourceText(program: .v2, file: file).contains(text), "v2 \(file) lacks: \(text)")
                case " ": #expect(catalog.sourceText(program: .v1, file: file).contains(text))
                    #expect(catalog.sourceText(program: .v2, file: file).contains(text))
                default: Issue.record("Unmarked diff line in \(file): \(line)")
                }
            }
        }
    }

    @Test("curated excerpts are substrings of the real version bytes")
    func excerptsBoundToBytes() throws {
        let catalog = try catalog()
        for program in SampleProgram.allCases {
            for file in ["domain.go", "queue.go", "worker.go"] {
                let excerpt = catalog.excerpt(program: program, file: file)
                #expect(!excerpt.isEmpty)
                for line in excerpt.split(separator: "\n", omittingEmptySubsequences: true) {
                    #expect(catalog.sourceText(program: program, file: file).contains(line))
                }
            }
        }
    }

    @Test("retained reports carry the actual nine check names, all passing")
    func checkNames() throws {
        let catalog = try catalog()
        let expected = [
            "TestOwnerIntent", "TestRevokedAccess", "TestActiveAccess",
            "TestAuditBeforeRelease", "TestAuditFailure", "TestTenantIsolation",
            "TestQueueDenial", "TestTenantLookup", "TestInvalidJob",
        ]
        #expect(Set(catalog.checkNames) == Set(expected))
        #expect(catalog.checkNames.count == 9)
        for program in SampleProgram.allCases {
            let check = try #require(catalog.check(for: program))
            #expect(check.passedCount == 9)
            #expect(check.tests.count == 9)
        }
    }

    @Test("sample program identities match the retained report bindings")
    func identityBinding() throws {
        let catalog = try catalog()
        for program in SampleProgram.allCases {
            let check = try #require(catalog.check(for: program))
            #expect(check.id == (program == .v1 ? "check-001" : "check-002"))
            #expect(check.status == "observed_pass")
            #expect(check.sourceHash.hasPrefix(program.sourceIdentityPrefix))
        }
    }

    @Test("retained revoked_after_enqueue: v1 exported with events, v2 refused without")
    func revokedScenario() throws {
        let catalog = try catalog()
        let v1 = try #require(catalog.observation(named: "revoked_after_enqueue", program: .v1))
        let v2 = try #require(catalog.observation(named: "revoked_after_enqueue", program: .v2))
        #expect(v1.status == "exported")
        #expect(v1.eventKinds == ["audit", "release"])
        #expect(v2.status == "access_revoked")
        #expect(v2.eventKinds.isEmpty)
        #expect(catalog.scenarioLine(for: .v1).contains("exported"))
        #expect(catalog.scenarioLine(for: .v2).contains("access_revoked"))
    }
}
