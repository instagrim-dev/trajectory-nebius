import XCTest

/// Live connected-repository flow through real product controls.
///
/// One launch, no resets, no injected state: Connect/import, accept
/// queue-time, generate A (real Muse via the companion), check, commit,
/// push, observe its exact-head run, then accept delivery-time and repeat
/// for B, then traverse A/B read-only. Fixture replay or API-only proof
/// would not satisfy this test — every beat taps the shipped controls
/// and waits on the companion/GitHub truth.
///
/// Requires the loopback companion at 127.0.0.1:8123 and one-job
/// ephemeral self-hosted runners listening when pushes land.
final class WorkbenchLiveFlowTests: XCTestCase {
    private var app: XCUIApplication!

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
    /// Search is bidirectional: the flow moves down-screen overall, but
    /// status/count/traversal reads move back up, and virtualized rows
    /// only exist while near the viewport.
    @discardableResult
    private func reveal(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        expose(identifier, file: file, line: line)
        for _ in 0..<12 {
            let el = element(identifier)
            guard el.exists else {
                expose(identifier, file: file, line: line)
                continue
            }
            let frame = el.frame
            let top = unobscuredTop()
            let bottom = unobscuredBottom()
            if frame.minY >= top && frame.maxY <= bottom && el.isHittable { return el }
            if frame.maxY > bottom { app.swipeUp() } else { app.swipeDown() }
            sleep(1)
        }
        let el = require(identifier, file: file, line: line)
        XCTAssertTrue(el.isHittable, "Control '\(identifier)' must be tappable.", file: file, line: line)
        return el
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
        // Defense in depth: if any keyboard lingers, its top — not the
        // toolbar — is the tappable limit.
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists { top = min(top, keyboard.frame.minY) }
        if top < CGFloat.greatestFiniteMagnitude { return top - 4 }
        return 700
    }

    /// Scroll a static row back into the hierarchy. SwiftUI Lists
    /// virtualize far off-screen rows out of existence, so a label that
    /// was asserted on-screen vanishes after scrolling to another
    /// section. Unlike reveal(), this needs existence only — static
    /// text is never hittable.
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

    /// Poll the live status line until it contains the fragment.
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

    /// Deterministically replace a text field's content through genuine
    /// native editing — delete every existing character, type the new
    /// value, then assert the field actually reads it back. Double-tap
    /// selection plus typeText can append or leave menu behavior behind,
    /// which must never decide what gets generated or committed.
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
        // Tapping away resigns the field: a lingering keyboard would
        // cover lower controls and make them untappable. Fail fast here
        // (before any expensive generation) if it does not dismiss.
        app.navigationBars.firstMatch.tap()
        sleep(1)
        XCTAssertFalse(app.keyboards.firstMatch.exists,
                       "Keyboard must dismiss after editing '\(identifier)'.",
                       file: file, line: line)
    }

    private func setCandidateName(_ name: String) {
        setTextField("live-candidate-name", to: name)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - The live loop, twice, then traversal

    func testLiveLoopAB() {
        app.launch()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 15))
        element("toolbar-live").tap()
        XCTAssertTrue(app.navigationBars["Live Workbench"].waitForExistence(timeout: 15))
        // The consequential question leads; provenance follows the outcome.
        XCTAssertTrue(element("live-question").waitForExistence(timeout: 15))
        shot("live-opening")

        // Connect + import the private demo repo at current main.
        reveal("live-connect").tap()
        waitStatus(containing: "Imported instagrim-dev/trajectory-nebius-demo", timeout: 180)

        // Prove deterministic field replacement BEFORE any expensive
        // model call: rewriting "A" with "A" must read back exactly.
        setCandidateName("A")

        // Accept queue-time intent (intent only — nothing generated).
        reveal("live-answer-queue_time").tap()
        reveal("live-accept").tap()
        waitStatus(containing: "Accepted Request-time", timeout: 60)
        XCTAssertTrue(expose("live-answer-queue_time").label.contains("Accepted"))

        // Generate A with the real model, then check it.
        reveal("live-generate").tap()
        waitStatus(containing: "Generated candidate A", timeout: 900)
        shot("live-generated-A")
        reveal("live-check").tap()
        waitStatus(containing: "Checks passed", timeout: 600)

        // Real source and diff through the controls, bound to A.
        reveal("live-load-source").tap()
        XCTAssertTrue(element("live-source-meta").waitForExistence(timeout: 30))
        XCTAssertTrue(element("live-source-meta").label.contains("A|queued/queue.go"))
        XCTAssertTrue(element("live-source-text").waitForExistence(timeout: 15))
        reveal("live-load-diff").tap()
        XCTAssertTrue(element("live-diff-meta").waitForExistence(timeout: 30))
        XCTAssertTrue(element("live-diff-meta").label.contains("candidate A"))
        XCTAssertTrue(element("live-diff-text").waitForExistence(timeout: 15))
        let diffA = element("live-diff-text").label
        XCTAssertFalse(diffA.isEmpty)

        // Commit A, then push it as a separate explicit action.
        setTextField("live-commit-message",
                     to: "Candidate A: queue-time authorization governs queued export")
        reveal("live-commit").tap()
        waitStatus(containing: "Committed", timeout: 180)
        expose("live-commit-sha")
        let commitStatusA = expose("live-status").label
        // Status reads "Committed <12hex> for candidate A..."; the
        // evidence row's VoiceOver label is "Commit, <12hex>". Compare
        // the SHA itself, not the surrounding prose.
        let committedSHA = commitStatusA.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        XCTAssertEqual(committedSHA.count, 12,
                       "Status '\(commitStatusA)' must name a commit SHA.")
        XCTAssertTrue(expose("live-commit-sha").label.contains(committedSHA),
                      "Evidence row must show the committed SHA \(committedSHA).")
        reveal("live-push").tap()
        waitStatus(containing: "Pushed", timeout: 300)

        // Observe A's exact-head run (self-hosted Mac runner).
        reveal("live-observe").tap()
        waitStatus(containing: "success", timeout: 900)
        expose("live-run-conclusion")
        XCTAssertTrue(expose("live-run-conclusion").label.contains("success"))
        shot("live-observed-A")

        // Revise: accept delivery-time, construct B as a real descendant.
        setCandidateName("B")
        reveal("live-answer-delivery_time").tap()
        reveal("live-accept").tap()
        waitStatus(containing: "Accepted Delivery-time", timeout: 60)
        XCTAssertTrue(expose("live-answer-delivery_time").label.contains("Accepted"))
        reveal("live-generate").tap()
        waitStatus(containing: "Generated candidate B", timeout: 900)
        reveal("live-check").tap()
        waitStatus(containing: "Checks passed", timeout: 600)
        setTextField("live-commit-message",
                     to: "Candidate B: delivery-time authorization governs queued export")
        reveal("live-commit").tap()
        waitStatus(containing: "Committed", timeout: 180)
        reveal("live-push").tap()
        waitStatus(containing: "Pushed", timeout: 300)

        // B's diff is its own evidence, distinct from A's.
        reveal("live-load-diff").tap()
        XCTAssertTrue(element("live-diff-meta").waitForExistence(timeout: 30))
        XCTAssertTrue(element("live-diff-meta").label.contains("candidate B"))
        let diffB = element("live-diff-text").label
        XCTAssertFalse(diffB.isEmpty)
        XCTAssertNotEqual(diffA, diffB, "A and B must show distinct diffs.")

        // Cancellation is responsive and honest: cancel the in-flight
        // observation, see the cancelled failure + next action, then
        // re-observe to the real outcome. If the run already finished,
        // the Cancel control is simply gone and observation stands.
        reveal("live-observe").tap()
        if element("live-cancel").waitForExistence(timeout: 30) {
            element("live-cancel").tap()
            waitStatus(containing: "cancelled", timeout: 120)
            XCTAssertTrue(expose("live-failure").label.contains("cancelled"))
            expose("live-next-action")
            reveal("live-observe").tap()
        }
        waitStatus(containing: "success", timeout: 900)
        expose("live-run-conclusion")
        XCTAssertTrue(expose("live-run-conclusion").label.contains("success"))
        shot("live-observed-B")

        // The decision map expresses both nodes and the accepted intent.
        XCTAssertTrue(expose("live-map-A").exists)
        XCTAssertTrue(expose("live-map-B").exists)
        XCTAssertTrue(expose("live-map-B").label.contains("accepted"))
        let countsBefore = expose("live-counts").label
        XCTAssertTrue(countsBefore.contains("2 candidates"), "Both candidates must be retained (label: \(countsBefore)).")
        XCTAssertTrue(countsBefore.contains("2 commits"))

        // Traverse: reopen A read-only — accepted B and all evidence stay,
        // and viewing creates no new generation/check/commit/push.
        reveal("live-candidate-A").tap()
        XCTAssertTrue(expose("live-answer-delivery_time").label.contains("Accepted"),
                      "Reopening A must preserve the accepted delivery-time intent.")
        XCTAssertEqual(expose("live-counts").label, countsBefore,
                       "Viewing A must not create new evidence.")
        XCTAssertTrue(expose("live-map-A").label.contains("viewing"))
        // A's own source/diff return; B's text does not linger.
        reveal("live-load-diff").tap()
        XCTAssertTrue(element("live-diff-meta").waitForExistence(timeout: 30))
        XCTAssertTrue(element("live-diff-meta").label.contains("candidate A"))
        XCTAssertEqual(expose("live-diff-text").label, diffA,
                       "Reopened A must show its own retained diff.")
        shot("live-traverse-A")
        reveal("live-candidate-B").tap()
        XCTAssertTrue(expose("live-answer-delivery_time").label.contains("Accepted"))
        XCTAssertEqual(expose("live-counts").label, countsBefore,
                       "Returning to B must not create new evidence either.")
    }
}
