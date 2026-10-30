import Testing
@testable import WorkbenchCore

/// Domain invariants protecting user-visible selected / accepted / viewed
/// semantics and report applicability. Pure Foundation, no UI.
struct WorkbenchStateTests {

    private func makeState() -> WorkbenchState {
        WorkbenchState(
            selected: .queueTime,
            accepted: .deliveryTime,
            viewed: .v1,
            retainedChecks: [
                RetainedCheck(id: "check-001", program: .v1, outcome: .passed),
                RetainedCheck(id: "check-002", program: .v2, outcome: .passed),
            ]
        )
    }

    @Test("selecting an answer never changes accepted intent")
    func selectingNeverAccepts() {
        var state = makeState()
        state.select(.queueTime)
        #expect(state.selected == .queueTime)
        #expect(state.accepted == .deliveryTime)
        #expect(state.isAcceptEnabled == true)
        state.select(.deliveryTime)
        #expect(state.selected == .deliveryTime)
        #expect(state.accepted == .deliveryTime)
        #expect(state.isAcceptEnabled == false)
    }

    @Test("accept is enabled only when selected differs from accepted")
    func acceptEnabledOnlyOnDifference() {
        var state = makeState()
        #expect(state.isAcceptEnabled)
        state.select(.deliveryTime)
        #expect(state.isAcceptEnabled == false)
        let changed = state.accept()
        #expect(changed == false)
        #expect(state.accepted == .deliveryTime)
    }

    @Test("accept adopts the selected answer")
    func acceptAdoptsSelected() {
        var state = makeState()
        let changed = state.accept()
        #expect(changed)
        #expect(state.accepted == .queueTime)
        #expect(state.isAcceptEnabled == false)
    }

    @Test("reopening a saved program changes viewed only, never accepted intent")
    func reopenKeepsAcceptedIntent() {
        var state = makeState()
        state.openProgram(.v2)
        #expect(state.viewed == .v2)
        #expect(state.accepted == .deliveryTime)
        #expect(state.selected == .queueTime)
        state.openProgram(.v1)
        #expect(state.viewed == .v1)
        #expect(state.accepted == .deliveryTime)
    }

    @Test("report applicability is independent of pass/fail outcome")
    func applicabilityIndependentOfOutcome() {
        var passing = makeState()
        passing.openProgram(.v1)
        var failing = passing
        failing.retainedChecks = [
            RetainedCheck(id: "check-001", program: .v1, outcome: .failed)
        ]
        var incomplete = passing
        incomplete.retainedChecks = [
            RetainedCheck(id: "check-001", program: .v1, outcome: .incomplete)
        ]
        // v1 viewed under delivery-time intent: historical whatever the outcome.
        #expect(passing.reportBinding == .historical)
        #expect(failing.reportBinding == .historical)
        #expect(incomplete.reportBinding == .historical)
    }

    @Test("current binding needs viewed program matching latest accepted intent")
    func currentBinding() {
        var state = makeState()
        state.accept() // accepted becomes queue-time, viewed is v1 (queue-time)
        #expect(state.accepted == .queueTime)
        #expect(state.reportBinding == .current)
    }

    @Test("program with no retained check is unchecked, never a historical pass")
    func noReportIsNotAHistoricalPass() {
        var state = makeState()
        state.retainedChecks = []
        state.openProgram(.v2)
        #expect(state.reportBinding == .unchecked)
        #expect(state.reportBinding != .historical)
        #expect(state.reportBinding != .current)
    }

    @Test("changed source or contract makes a retained check mismatched")
    func mismatchedOnChangedSource() {
        var state = makeState()
        state.accept() // queue-time intent, v1 viewed: would be current
        #expect(state.reportBinding == .current)
        state.sourceChanged = true
        #expect(state.reportBinding == .mismatched)
    }
}
