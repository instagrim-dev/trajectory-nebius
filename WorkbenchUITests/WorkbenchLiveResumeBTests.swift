import XCTest

/// Focused saved-session continuation: resume the real persisted session
/// ad6186198e7d (accepted delivery_time, A pushed/observed, B generated
/// but uncommitted) through genuine product controls, then finish B —
/// check, source/diff, commit, push, observe its exact-head SUCCESS run —
/// and prove read-only traversal to historical A preserves accepted B.
///
/// This test never imports, accepts, or generates: B's original actual
/// generation receipt stands. One launch, no resets, no injected state.
/// Requires the loopback companion at 127.0.0.1:8123 and a one-job
/// ephemeral self-hosted runner listening when B's push lands.
final class WorkbenchLiveResumeBTests: XCTestCase {
    private var app: XCUIApplication!

    func testScratchWitnessCapture() throws {
        guard let session = ProcessInfo.processInfo.environment["TRAJECTORY_WITNESS_SESSION"], !session.isEmpty else {
            throw XCTSkip("Set TRAJECTORY_WITNESS_SESSION to a prepared scratch witness session.")
        }
        app.launch()
        require("toolbar-live").tap()
        let resume = reveal("live-resume-id")
        if (resume.value as? String) != session {
            setTextField("live-resume-id", to: session)
        }
        XCTAssertEqual(element("live-resume-id").value as? String, session)
        app.buttons["live-resume"].tap()
        waitStatus(containing: "Resumed session", timeout: 60)
        expose("live-candidate-Broken").tap()
        app.buttons["live-operations-toggle"].tap()
        expose("live-check").tap()
        waitStatus(containing: "Check failed", timeout: 120)
        expose("live-candidate-Good")
        XCTAssertTrue(app.buttons["live-candidate-Broken"].label.contains("Check failed"))
        XCTAssertTrue(app.buttons["live-candidate-Good"].label.contains("Checks passed"))
        app.buttons["live-candidate-Good"].tap()
        let outcome = expose("live-outcome")
        XCTAssertTrue(outcome.label.contains("passed"), outcome.label)
    }


    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @discardableResult
    private func require(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let el = element(identifier)
        XCTAssertTrue(el.waitForExistence(timeout: 15),
                      "Expected control '\(identifier)' to exist.", file: file, line: line)
        return el
    }

    /// Scroll until the control exists and sits clear of the nav bar and
    /// the floating bottom toolbar, then return it for a genuine tap.
    /// The loop remembers its last scroll direction: a row that vanishes
    /// was overshot, so the next move reverses instead of re-searching
    /// blindly and oscillating. A row inside the viewport but covered
    /// (sticky section header) is nudged a short drag away from the
    /// nearest edge — a full swipe from there overshoots and virtualizes
    /// it again.
    @discardableResult
    private func reveal(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        expose(identifier, file: file, line: line)
        var lastDir = 0
        for _ in 0..<30 {
            let el = element(identifier)
            if !el.exists {
                if lastDir >= 0 { app.swipeDown(); lastDir = -1 } else { app.swipeUp(); lastDir = 1 }
                sleep(1)
                continue
            }
            let frame = el.frame
            let top = unobscuredTop()
            let bottom = unobscuredBottom()
            if frame.minY >= top && frame.maxY <= bottom && el.isHittable { return el }
            if frame.minY >= bottom || (frame.maxY > bottom && frame.minY >= top) {
                app.swipeUp()
                lastDir = 1
            } else if frame.maxY <= top || frame.minY < top {
                app.swipeDown()
                lastDir = -1
            } else {
                let nearTop = frame.midY < (top + bottom) / 2
                nudge(awayFromTop: nearTop)
                lastDir = nearTop ? -1 : 1
            }
            sleep(1)
        }
        let el = require(identifier, file: file, line: line)
        XCTAssertTrue(el.isHittable, "Control '\(identifier)' must be tappable.", file: file, line: line)
        return el
    }

    /// Short directional drag for fine positioning: moves content a
    /// fraction of the screen instead of a full swipe's overshoot.
    private func nudge(awayFromTop: Bool) {
        let height = app.frame.height
        guard height > 0 else {
            if awayFromTop { app.swipeDown() } else { app.swipeUp() }
            return
        }
        let dist = min(160 / height, 0.3)
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = app.coordinate(withNormalizedOffset: CGVector(
            dx: 0.5, dy: awayFromTop ? 0.5 + dist : 0.5 - dist))
        from.press(forDuration: 0.1, thenDragTo: to)
    }

    private func unobscuredTop() -> CGFloat {
        let nav = app.navigationBars.firstMatch
        if nav.exists { return nav.frame.maxY + 4 }
        return 140
    }

    private func unobscuredBottom() -> CGFloat {
        var top = CGFloat.greatestFiniteMagnitude
        for id in ["toolbar-map", "toolbar-preview", "toolbar-compare", "toolbar-report", "toolbar-live"] {
            let chrome = element(id)
            if chrome.exists { top = min(top, chrome.frame.minY) }
        }
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists { top = min(top, keyboard.frame.minY) }
        if top < CGFloat.greatestFiniteMagnitude { return top - 4 }
        return 700
    }

    @discardableResult
    private func expose(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        var el = element(identifier)
        if el.exists { return el }
        for _ in 0..<10 {
            app.swipeUp()
            sleep(1)
            el = element(identifier)
            if el.exists { return el }
        }
        for _ in 0..<10 {
            app.swipeDown()
            sleep(1)
            el = element(identifier)
            if el.exists { return el }
        }
        return require(identifier, file: file, line: line)
    }

    private func waitStatus(containing fragment: String, timeout: TimeInterval,
                           file: StaticString = #filePath, line: UInt = #line) {
        expose("live-status", file: file, line: line)
        let deadline = Date().addingTimeInterval(timeout)
        var label = ""
        while Date() < deadline {
            let el = element("live-status")
            if el.exists {
                label = el.label
                if label.contains(fragment) { return }
            } else {
                expose("live-status", file: file, line: line)
            }
            sleep(5)
        }
        expose("live-status", file: file, line: line)
        label = element("live-status").label
        XCTAssertTrue(label.contains(fragment),
                      "Status '\(label)' never contained '\(fragment)'.",
                      file: file, line: line)
    }

    private func setTextField(_ identifier: String, to value: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let field = reveal(identifier, file: file, line: line)
        field.tap()
        let current = (field.value as? String) ?? ""
        for _ in current {
            app.keys["delete"].tap()
        }
        field.typeText(value)
        let actual = (element(identifier).value as? String) ?? ""
        XCTAssertEqual(actual, value,
                       "Field '\(identifier)' must read back exactly what was set.",
                       file: file, line: line)
        // Resign through the keyboard's own Return key first, then by
        // tapping away: a lingering keyboard would cover lower controls
        // and make them untappable. Fail fast here if it does not dismiss.
        if app.keyboards.firstMatch.exists {
            let ret = app.keyboards.buttons["Return"]
            if ret.waitForExistence(timeout: 5) { ret.tap() }
        }
        app.navigationBars.firstMatch.tap()
        sleep(2)
        XCTAssertFalse(app.keyboards.firstMatch.exists,
                       "Keyboard must dismiss after editing '\(identifier)'.",
                       file: file, line: line)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Resume B, finish it, traverse A

    func testSavedSourceShortcutsReachEvidenceAndHistory() {
        app.launch()
        require("toolbar-live").tap()
        setTextField("live-resume-id", to: "ad6186198e7d")
        reveal("live-resume").tap()
        waitStatus(containing: "Resumed session ad618619", timeout: 60)

        // Resume opens historical A while the delivery-time rule stays accepted.
        reveal("live-jump-evidence").tap()
        XCTAssertTrue(require("live-view-context").label.contains("A"))
        XCTAssertTrue(require("live-outcome").label.contains("exported"))
        reveal("live-evidence-jump-history").tap()
        XCTAssertTrue(require("live-map-accepted").label.contains("Delivery"))
        XCTAssertTrue(require("live-map-A").label.contains("viewing"))
        reveal("live-jump-history").tap()
        XCTAssertTrue(require("live-map-A").label.contains("viewing"))
    }

    func testResumeFinishBTraverseA() {
        app.launch()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 15))
        element("toolbar-live").tap()
        XCTAssertTrue(app.navigationBars["Live Workbench"].waitForExistence(timeout: 15))
        XCTAssertTrue(element("live-question").waitForExistence(timeout: 15))
        shot("resume-opening")

        // Resume the saved live session through the real product control.
        // No import, no accept, no generation: persisted truth only.
        setTextField("live-resume-id", to: "ad6186198e7d")
        reveal("live-resume").tap()
        waitStatus(containing: "Resumed session ad618619", timeout: 60)
        XCTAssertTrue(expose("live-session").label.contains("ad6186198e7d"),
                      "Resumed session identity must be the saved session.")
        XCTAssertTrue(expose("live-answer-delivery_time").label.contains("Accepted"),
                      "Resume must restore the accepted delivery-time intent.")
        XCTAssertTrue(expose("live-map-A").exists)
        XCTAssertTrue(expose("live-map-B").exists)
        XCTAssertTrue(expose("live-map-B").label.contains("accepted"),
                      "Decision map must still mark B accepted after resume.")
        shot("resume-restored")

        // View B: the generated-but-uncommitted candidate.
        reveal("live-candidate-B").tap()

        // Independent checks on B through the control.
        reveal("live-check").tap()
        waitStatus(containing: "Checks passed", timeout: 600)

        // Real B source and A→B diff through the controls.
        reveal("live-load-source").tap()
        XCTAssertTrue(element("live-source-meta").waitForExistence(timeout: 30))
        XCTAssertTrue(element("live-source-meta").label.contains("B|queued/queue.go"))
        XCTAssertTrue(element("live-source-text").waitForExistence(timeout: 15))
        reveal("live-load-diff").tap()
        XCTAssertTrue(element("live-diff-meta").waitForExistence(timeout: 30))
        XCTAssertTrue(element("live-diff-meta").label.contains("candidate B"))
        XCTAssertTrue(element("live-diff-text").waitForExistence(timeout: 15))
        let diffB = element("live-diff-text").label
        XCTAssertFalse(diffB.isEmpty, "B must show its own diff.")

        // Commit B as a separate explicit action.
        setTextField("live-commit-message",
                     to: "Candidate B: delivery-time authorization governs queued export")
        reveal("live-commit").tap()
        waitStatus(containing: "Committed", timeout: 180)
        expose("live-commit-sha")
        let commitStatusB = expose("live-status").label
        let committedSHA = commitStatusB.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        XCTAssertEqual(committedSHA.count, 12,
                       "Status '\(commitStatusB)' must name a commit SHA.")
        XCTAssertTrue(expose("live-commit-sha").label.contains(committedSHA),
                      "Evidence row must show the committed SHA \(committedSHA).")

        // Push B explicitly, then observe its exact-head run.
        reveal("live-push").tap()
        waitStatus(containing: "Pushed", timeout: 300)
        reveal("live-observe").tap()
        waitStatus(containing: "success", timeout: 900)
        expose("live-run-conclusion")
        XCTAssertTrue(expose("live-run-conclusion").label.contains("success"),
                      "B's exact-head run must conclude success.")
        shot("resume-observed-B")

        // Both nodes and the accepted intent on the map.
        XCTAssertTrue(expose("live-map-A").exists)
        XCTAssertTrue(expose("live-map-B").exists)
        XCTAssertTrue(expose("live-map-B").label.contains("accepted"))
        let countsFinal = expose("live-counts").label
        XCTAssertTrue(countsFinal.contains("2 candidates"),
                      "Both candidates must be retained (label: \(countsFinal)).")
        XCTAssertTrue(countsFinal.contains("2 commits"),
                      "Both commits must be retained (label: \(countsFinal)).")

        // Traverse: reopen historical A read-only — accepted B and all
        // evidence stay, and viewing creates no new
        // generation/check/commit/push.
        reveal("live-candidate-A").tap()
        XCTAssertTrue(expose("live-answer-delivery_time").label.contains("Accepted"),
                      "Reopening A must preserve the accepted delivery-time intent.")
        XCTAssertEqual(expose("live-counts").label, countsFinal,
                       "Viewing A must not create new evidence.")
        XCTAssertTrue(expose("live-map-A").label.contains("viewing"))
        reveal("live-load-diff").tap()
        XCTAssertTrue(element("live-diff-meta").waitForExistence(timeout: 30))
        XCTAssertTrue(element("live-diff-meta").label.contains("candidate A"))
        XCTAssertTrue(element("live-diff-text").waitForExistence(timeout: 15))
        let diffA = expose("live-diff-text").label
        XCTAssertFalse(diffA.isEmpty, "Reopened A must show its own retained diff.")
        XCTAssertNotEqual(diffA, diffB, "A and B must show distinct diffs.")
        shot("resume-traverse-A")

        // Return to B with its own current evidence, still unchanged.
        reveal("live-candidate-B").tap()
        XCTAssertTrue(expose("live-answer-delivery_time").label.contains("Accepted"))
        XCTAssertEqual(expose("live-counts").label, countsFinal,
                       "Returning to B must not create new evidence either.")
    }

    // MARK: - Finished-B traversal (read-only, re-runnable)

    /// Resume the saved session after B is committed, pushed, and
    /// observed, and prove read-only traversal: B's finished evidence is
    /// intact, historical A shows its own evidence with accepted B
    /// preserved, and returning to B changes nothing. No mutations —
    /// commit/push/observe already happened and must not be duplicated.
    func testResumeBTraversalIntact() {
        app.launch()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 15))
        element("toolbar-live").tap()
        XCTAssertTrue(app.navigationBars["Live Workbench"].waitForExistence(timeout: 15))
        XCTAssertTrue(element("live-question").waitForExistence(timeout: 15))

        setTextField("live-resume-id", to: "ad6186198e7d")
        reveal("live-resume").tap()
        waitStatus(containing: "Resumed session ad618619", timeout: 60)
        app.buttons["live-connection-toggle"].tap()
        XCTAssertTrue(expose("live-session").label.contains("ad6186198e7d"),
                      "Resumed session identity must be the saved session.")
        XCTAssertTrue(expose("live-answer-delivery_time").label.contains("Accepted"),
                      "Resume must restore the accepted delivery-time intent.")

        // B's finished evidence, viewed read-only through the controls.
        reveal("live-candidate-B").tap()
        XCTAssertTrue(expose("live-commit-sha").label.contains("4bdb6c0cc000"),
                      "B must show its committed SHA.")
        XCTAssertTrue(expose("live-run-conclusion").label.contains("40543004225"),
                      "B must show its exact-head run.")
        XCTAssertTrue(expose("live-run-conclusion").label.contains("success"))
        XCTAssertTrue(expose("live-outcome").label.contains("access_revoked"),
                      "B's applicable check must report access_revoked.")
        reveal("live-load-source").tap()
        XCTAssertTrue(element("live-source-meta").waitForExistence(timeout: 30))
        XCTAssertTrue(element("live-source-meta").label.contains("B|queued/worker.go"))
        reveal("live-load-diff").tap()
        XCTAssertTrue(element("live-diff-meta").waitForExistence(timeout: 30))
        XCTAssertTrue(element("live-diff-meta").label.contains("candidate B"))
        let diffLines = app.staticTexts.matching(identifier: "live-diff-text")
        XCTAssertTrue(diffLines.firstMatch.waitForExistence(timeout: 15))
        let diffB = diffLines.allElementsBoundByIndex.map { $0.label }.joined(separator: "\n")
        XCTAssertFalse(diffB.isEmpty)
        XCTAssertTrue(expose("live-map-A").exists)
        XCTAssertTrue(expose("live-map-B").exists)
        XCTAssertTrue(expose("live-map-B").label.contains("accepted"))
        let countsFinal = expose("live-counts").label
        XCTAssertTrue(countsFinal.contains("2 candidates"),
                      "Both candidates must be retained (label: \(countsFinal)).")
        XCTAssertTrue(countsFinal.contains("2 commits"),
                      "Both commits must be retained (label: \(countsFinal)).")
        shot("intact-B")

        // Traverse to historical A: accepted B stays, A's own evidence
        // returns, and viewing creates nothing.
        reveal("live-candidate-A").tap()
        XCTAssertTrue(expose("live-answer-delivery_time").label.contains("Accepted"),
                      "Viewing A must preserve the accepted delivery-time intent.")
        XCTAssertEqual(expose("live-counts").label, countsFinal,
                       "Viewing A must not create new evidence.")
        XCTAssertTrue(expose("live-map-A").label.contains("viewing"))
        XCTAssertTrue(expose("live-commit-sha").label.contains("5adf3fa8626f"),
                      "A must show its own commit.")
        XCTAssertTrue(expose("live-run-conclusion").label.contains("40535341214"),
                      "A must show its own exact-head run.")
        XCTAssertTrue(expose("live-run-conclusion").label.contains("success"))
        XCTAssertTrue(expose("live-outcome").label.contains("exported"),
                      "A's applicable check must report exported.")
        reveal("live-load-diff").tap()
        // The load button sits after the diff. Walk upward through the diff
        // instead of searching downward first, which can lose the heading.
        for _ in 0..<60 {
            if element("live-diff-meta").exists { break }
            app.swipeDown()
        }
        XCTAssertTrue(require("live-diff-meta").label.contains("candidate A"))
        XCTAssertTrue(diffLines.firstMatch.waitForExistence(timeout: 15))
        let diffA = diffLines.allElementsBoundByIndex.map { $0.label }.joined(separator: "\n")
        XCTAssertFalse(diffA.isEmpty)
        XCTAssertNotEqual(diffA, diffB, "A and B must show distinct diffs.")
        shot("intact-traverse-A")

        // Return to B with its own current evidence, still unchanged.
        // The candidate list follows the full diff, which may span many screens.
        for _ in 0..<60 {
            if element("live-candidate-B").exists { break }
            app.swipeUp()
        }
        reveal("live-candidate-B").tap()
        XCTAssertTrue(expose("live-answer-delivery_time").label.contains("Accepted"))
        XCTAssertEqual(expose("live-counts").label, countsFinal,
                       "Returning to B must not create new evidence either.")
        XCTAssertTrue(expose("live-commit-sha").label.contains("4bdb6c0cc000"),
                      "Returned B must show its own commit again.")
        shot("intact-return-B")
    }

    // MARK: - Quorum remediation (read-only, re-runnable)

    /// Resume the finished session and prove the three quorum
    /// corrections through real product controls: the map roots A at
    /// its immutable source parent (never at current main B), each
    /// viewed candidate states its observed release/block consequence
    /// beside the decisive worker.go guard, and View/Return controls
    /// beside the accepted/viewed context traverse B → A → B without
    /// changing accepted intent, records, counts, or remote evidence.
    /// No generate/check/commit/push/observe is touched.
    func testRemediationAncestryConsequenceGuardTraversal() {
        app.launch()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 15))
        element("toolbar-live").tap()
        XCTAssertTrue(app.navigationBars["Live Workbench"].waitForExistence(timeout: 15))
        XCTAssertTrue(element("live-question").waitForExistence(timeout: 15))

        setTextField("live-resume-id", to: "ad6186198e7d")
        reveal("live-resume").tap()
        waitStatus(containing: "Resumed session ad618619", timeout: 60)
        XCTAssertTrue(expose("live-session").label.contains("ad6186198e7d"),
                      "Resumed session identity must be the saved session.")
        XCTAssertTrue(expose("live-answer-delivery_time").label.contains("Accepted"),
                      "Resume must restore the accepted delivery-time intent.")

        // Correction 1: the map roots A at its immutable source parent
        // even though current main has advanced to B.
        let mapA = expose("live-map-A").label
        XCTAssertTrue(mapA.contains("baseline b6b929cec75f"),
                      "A's map ancestry must read its source parent, not current main (label: \(mapA)).")
        XCTAssertFalse(mapA.contains("4bdb6c0cc000"),
                       "A's ancestry must never name B's commit (label: \(mapA)).")
        XCTAssertTrue(expose("live-map-baseline-A").label.contains("b6b929cec75f"))
        let mapB = expose("live-map-B").label
        XCTAssertTrue(mapB.contains("parent Candidate A"),
                      "B's map ancestry must name Candidate A (label: \(mapB)).")

        // View B through the evidence context control.
        reveal("live-view-B").tap()
        XCTAssertTrue(expose("live-view-context").label.contains(
            "Accepted: delivery-time · Viewing: B (current)"),
                      "B context must name accepted intent and current cursor.")
        XCTAssertTrue(expose("live-consequence").label.contains(
            "Delivery was blocked; nothing was released"),
                      "B must state its observed blocked consequence.")
        XCTAssertTrue(expose("live-outcome").label.contains("access_revoked"))
        XCTAssertTrue(expose("live-commit-sha").label.contains("4bdb6c0cc000"))
        XCTAssertTrue(expose("live-run-conclusion").label.contains("40543004225"))
        let countsFinal = expose("live-counts").label
        XCTAssertTrue(countsFinal.contains("2 candidates"))
        XCTAssertTrue(countsFinal.contains("2 commits"))

        // Correction 2 (guard): load the viewed worker.go through the
        // picker and read the decisive guard beside the consequence.
        reveal("live-source-picker").tap()
        element("worker.go").tap()
        XCTAssertTrue(expose("live-source-path").label.contains("queued/worker.go"),
                      "The full selected path must stay visible beside short labels.")
        reveal("live-load-source").tap()
        XCTAssertTrue(element("live-source-meta").waitForExistence(timeout: 30))
        XCTAssertTrue(element("live-source-meta").label.contains("B|queued/worker.go"))
        let guardB = expose("live-guard-excerpt").label
        XCTAssertTrue(guardB.contains("if !access.Allowed(job.TenantID, job.UserID) {"),
                      "B's guard must be the live delivery-time check (excerpt: \(guardB)).")
        shot("remediation-B")

        // Correction 3: traverse to historical A via the View control;
        // accepted B, ancestry, and counts stay fixed.
        reveal("live-view-A").tap()
        XCTAssertTrue(expose("live-view-context").label.contains(
            "Accepted: delivery-time · Viewing: A (historical)"),
                      "Viewing A must keep accepted B visible beside the cursor.")
        XCTAssertTrue(expose("live-consequence").label.contains(
            "The customer records package was still released"),
                      "A must state its observed released consequence.")
        XCTAssertTrue(expose("live-outcome").label.contains("exported"))
        XCTAssertTrue(expose("live-commit-sha").label.contains("5adf3fa8626f"))
        XCTAssertTrue(expose("live-run-conclusion").label.contains("40535341214"))
        XCTAssertEqual(expose("live-counts").label, countsFinal,
                       "Viewing A must not create new evidence.")
        XCTAssertTrue(expose("live-map-A").label.contains("baseline b6b929cec75f"),
                      "A's ancestry must survive traversal.")
        XCTAssertTrue(expose("live-map-B").label.contains("parent Candidate A"))
        XCTAssertTrue(expose("live-return-B").exists,
                      "Historical A must offer a direct return control.")
        reveal("live-load-source").tap()
        XCTAssertTrue(element("live-source-meta").waitForExistence(timeout: 30))
        XCTAssertTrue(element("live-source-meta").label.contains("A|queued/worker.go"))
        let guardA = expose("live-guard-excerpt").label
        XCTAssertTrue(guardA.contains("if !job.PermissionSnapshot {"),
                      "A's guard must be the queue-time snapshot check (excerpt: \(guardA)).")
        XCTAssertNotEqual(guardA, guardB, "A and B must show distinct guards.")
        shot("remediation-traverse-A")

        // The map itself is actionable: tap B's map row, then return
        // through the direct return control.
        reveal("live-map-B").tap()
        XCTAssertTrue(expose("live-view-context").label.contains("Viewing: B (current)"))
        reveal("live-view-A").tap()
        XCTAssertTrue(expose("live-view-context").label.contains("Viewing: A (historical)"))
        reveal("live-return-B").tap()
        XCTAssertTrue(expose("live-view-context").label.contains("Viewing: B (current)"),
                      "Return must restore B's current evidence.")
        XCTAssertTrue(expose("live-answer-delivery_time").label.contains("Accepted"))
        XCTAssertEqual(expose("live-counts").label, countsFinal,
                       "Returning to B must not create new evidence either.")
        XCTAssertTrue(expose("live-commit-sha").label.contains("4bdb6c0cc000"))
        XCTAssertTrue(expose("live-map-A").label.contains("baseline b6b929cec75f"))
        shot("remediation-return-B")
    }

    // MARK: - Framing witness (read-only, re-runnable)

    /// Static combined-viewport witness for the production seat: in one
    /// unobscured native viewport show accepted/viewed context, the
    /// actual switch control, and the observed consequence together —
    /// first for historical A (context + Return to B + released), then
    /// via that Return control for current B (context + View A +
    /// blocked). No source/guard loading, no mutations; the guard,
    /// ancestry, and provenance closures rest on the prior frames.
    /// Frame bounds are asserted simultaneously, not as sequential
    /// exists checks. Real resume control, real taps, real scrolling.
    func testFramingCombinedViewportWitness() {
        app.launch()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 15))
        element("toolbar-live").tap()
        XCTAssertTrue(app.navigationBars["Live Workbench"].waitForExistence(timeout: 15))
        XCTAssertTrue(element("live-question").waitForExistence(timeout: 15))

        setResumeField(to: "ad6186198e7d")
        reveal("live-resume").tap()
        waitStatus(containing: "Resumed session ad618619", timeout: 60)
        XCTAssertTrue(expose("live-session").label.contains("ad6186198e7d"),
                      "Resumed session identity must be the saved session.")
        XCTAssertTrue(expose("live-answer-delivery_time").label.contains("Accepted"),
                      "Resume must restore the accepted delivery-time intent.")

        // View historical A through the real candidate control.
        reveal("live-candidate-A").tap()
        XCTAssertTrue(expose("live-view-context").label.contains(
            "Accepted: delivery-time · Viewing: A (historical)"),
                      "Viewing A must keep accepted B visible beside the cursor.")
        XCTAssertTrue(expose("live-consequence").label.contains(
            "The customer records package was still released"),
                      "A must state its observed released consequence.")
        XCTAssertTrue(expose("live-return-B").exists,
                      "Historical A must offer the direct return control.")

        // Align the evidence card top so context/controls sit above the
        // crop instead of the consequence-first framing of prior PNGs.
        alignEvidenceTop()
        let reportA = assertTogether(
            contextID: "live-view-context",
            controlID: "live-return-B",
            consequenceID: "live-consequence",
            expectedContext: "Accepted: delivery-time · Viewing: A (historical)",
            expectedConsequence: "The customer records package was still released",
            tag: "FRAMING-WITNESS-A")
        shot("framing-A-combined")
        XCTAssertTrue(expose("live-counts").label.contains("2 candidates"))
        XCTAssertTrue(expose("live-counts").label.contains("2 verifications"))
        XCTAssertTrue(expose("live-counts").label.contains("2 commits"))
        XCTAssertTrue(expose("live-map-B").label.contains("accepted"),
                      "Accepted B must survive the A traversal.")

        // Return through the actual on-screen control, not a map row.
        witnessTap("live-return-B")
        XCTAssertTrue(expose("live-view-context").label.contains(
            "Accepted: delivery-time · Viewing: B (current)"),
                      "Return must restore B's current evidence.")
        XCTAssertTrue(expose("live-consequence").label.contains(
            "Delivery was blocked; nothing was released"),
                      "B must state its observed blocked consequence.")
        XCTAssertTrue(expose("live-view-A").exists,
                      "Current B must offer the View A control.")
        alignEvidenceTop()
        let reportB = assertTogether(
            contextID: "live-view-context",
            controlID: "live-view-A",
            consequenceID: "live-consequence",
            expectedContext: "Accepted: delivery-time · Viewing: B (current)",
            expectedConsequence: "Delivery was blocked; nothing was released",
            tag: "FRAMING-WITNESS-B")
        shot("framing-B-combined")
        XCTAssertTrue(expose("live-answer-delivery_time").label.contains("Accepted"))
        XCTAssertTrue(expose("live-counts").label.contains("2 candidates"))
        XCTAssertTrue(expose("live-counts").label.contains("2 verifications"))
        XCTAssertTrue(expose("live-counts").label.contains("2 commits"))
        XCTAssertTrue(expose("live-commit-sha").label.contains("4bdb6c0cc000"),
                      "Returned B must show its own commit again.")
        print("FRAMING-SUMMARY A[\(reportA)] B[\(reportB)]")
    }

    /// Scroll until the evidence context line sits at the top of the
    /// unobscured viewport, so the context/switch row and the
    /// consequence share one viewport with it. Each step measures the
    /// remaining delta and drags exactly that far at low velocity with
    /// a terminal hold, then settles before re-measuring — no inertia,
    /// no fixed-step ping-pong. No full swipes here.
    private func alignEvidenceTop(file: StaticString = #filePath, line: UInt = #line) {
        let context = reveal("live-view-context", file: file, line: line)
        XCTAssertTrue(context.exists, file: file, line: line)
        for _ in 0..<15 {
            let frame = element("live-view-context").frame
            let top = unobscuredTop()
            if frame.minY >= top && frame.minY <= top + 120 { return }
            slowShift(by: (top + 60) - frame.minY)
            sleep(2)
        }
        let frame = element("live-view-context").frame
        XCTAssertTrue(frame.minY >= unobscuredTop() && frame.minY <= unobscuredTop() + 120,
                      "Evidence context must align near viewport top (minY: \(frame.minY)).",
                      file: file, line: line)
    }

    /// Slow bounded content drag: moves content by `delta` points
    /// (positive moves content down, following the finger) at low
    /// velocity with a terminal hold, so inertial coasting cannot carry
    /// the card past the 120pt acceptance band. Per-step travel is
    /// clamped so one stale frame read can never fling the card across
    /// the viewport; sub-5pt residuals are left to settle instead of
    /// chased.
    private func slowShift(by delta: CGFloat) {
        let height = app.frame.height
        guard height > 0 else { return }
        let clamped = min(max(delta, -100), 100)
        guard abs(clamped) >= 5 else { return }
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = app.coordinate(withNormalizedOffset: CGVector(
            dx: 0.5, dy: 0.5 + clamped / height))
        from.press(forDuration: 0.2, thenDragTo: to, withVelocity: 80, thenHoldForDuration: 0.5)
    }

    /// Set the persisted resume field without per-character delete taps:
    /// the model keeps the last session ID across launches, so the field
    /// is usually already correct (tap-and-continue), and a differing
    /// value is replaced via word selection instead of the keyboard
    /// delete key, whose AX scroll-to-visible flakes in the simulator.
    private func setResumeField(to value: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let field = reveal("live-resume-id", file: file, line: line)
        let current = (element("live-resume-id").value as? String) ?? ""
        if current == value {
            // Persisted across launches: already correct, so never focus
            // the field and never raise the keyboard.
            return
        }
        field.tap()
        sleep(2)
        field.doubleTap()
        sleep(1)
        field.typeText(value)
        let actual = (element("live-resume-id").value as? String) ?? ""
        XCTAssertEqual(actual, value,
                       "Resume field must read back exactly what was set.",
                       file: file, line: line)
        // Tap Return only once the key reports hittable: tapping during
        // the keyboard-appear animation fails AX scroll-to-visible.
        let ret = app.keyboards.buttons["Return"]
        for _ in 0..<10 {
            if !app.keyboards.firstMatch.exists { break }
            if ret.exists && ret.isHittable { ret.tap(); break }
            sleep(1)
        }
        app.navigationBars.firstMatch.tap()
        sleep(2)
        XCTAssertFalse(app.keyboards.firstMatch.exists,
                       "Keyboard must dismiss after editing resume field.",
                       file: file, line: line)
    }

    /// Tap an already on-screen control without re-scrolling away from
    /// the framed viewport when possible; fall back to reveal().
    private func witnessTap(_ identifier: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let el = element(identifier)
        if el.exists && el.isHittable {
            let frame = el.frame
            if frame.minY >= unobscuredTop() && frame.maxY <= unobscuredBottom() {
                el.tap()
                sleep(2)
                return
            }
        }
        reveal(identifier, file: file, line: line).tap()
        sleep(2)
    }

    /// Assert context, switch control, and consequence labels and prove
    /// all three frames lie inside one unobscured viewport in a single
    /// simultaneous pass. Returns a compact bounds report and prints a
    /// machine-readable FRAMING line for the receipt.
    @discardableResult
    private func assertTogether(contextID: String, controlID: String,
                                consequenceID: String, expectedContext: String,
                                expectedConsequence: String, tag: String,
                                file: StaticString = #filePath,
                                line: UInt = #line) -> String {
        let context = element(contextID)
        let control = element(controlID)
        let consequence = element(consequenceID)
        XCTAssertTrue(context.exists, "Context '\(contextID)' must exist.", file: file, line: line)
        XCTAssertTrue(control.exists, "Control '\(controlID)' must exist.", file: file, line: line)
        XCTAssertTrue(consequence.exists, "Consequence '\(consequenceID)' must exist.", file: file, line: line)
        XCTAssertTrue(context.label.contains(expectedContext),
                      "Context must read '\(expectedContext)' (label: \(context.label)).",
                      file: file, line: line)
        XCTAssertTrue(consequence.label.contains(expectedConsequence),
                      "Consequence must contain '\(expectedConsequence)' (label: \(consequence.label)).",
                      file: file, line: line)
        let top = unobscuredTop()
        let bottom = unobscuredBottom()
        let cf = context.frame
        let tf = control.frame
        let qf = consequence.frame
        let report = "viewport=[\(Int(top))-\(Int(bottom))] " +
            "\(contextID)=[\(Int(cf.minY))-\(Int(cf.maxY))] " +
            "\(controlID)=[\(Int(tf.minY))-\(Int(tf.maxY))] " +
            "\(consequenceID)=[\(Int(qf.minY))-\(Int(qf.maxY))]"
        print("\(tag) \(report) context=\(context.label) control=\(control.label) consequence=\(consequence.label)")
        XCTAssertTrue(cf.minY >= top && cf.maxY <= bottom,
                      "Context frame must lie in viewport (\(report)).", file: file, line: line)
        XCTAssertTrue(tf.minY >= top && tf.maxY <= bottom,
                      "Switch-control frame must lie in viewport (\(report)).", file: file, line: line)
        XCTAssertTrue(qf.minY >= top && qf.maxY <= bottom,
                      "Consequence frame must lie in viewport (\(report)).", file: file, line: line)
        XCTAssertTrue(control.isHittable,
                      "Switch control '\(controlID)' must be tappable in place.", file: file, line: line)
        return report
    }
}
