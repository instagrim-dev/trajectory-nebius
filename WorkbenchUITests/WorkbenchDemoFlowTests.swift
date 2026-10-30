import XCTest

/// Genuine native control rehearsal for the Trajectory Workbench sample.
///
/// Each beat launches the app fresh (in-memory sample state resets to the
/// opening owner question), performs real XCUI control taps — never launch
/// arguments, state edits, or synthetic scenes — and holds key screens so a
/// simultaneous `simctl io recordVideo` take captures readable frames.
/// Beats double as the demo recording takes: run one beat per take with
/// `-only-testing:WorkbenchUITests/WorkbenchDemoFlowTests/<beat>`.
///
/// Beats never construct programs, run checks, or contact a service; they
/// select, explicitly accept, preview/compare read-only, open saved sample
/// programs, and read retained fixture reports.
final class WorkbenchDemoFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - Helpers

    /// Any element carrying the identifier, regardless of exposed type
    /// (SwiftUI Button/Link/SegmentedControl all resolve here).
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @discardableResult
    private func require(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let el = element(identifier)
        XCTAssertTrue(
            el.waitForExistence(timeout: 10),
            "Expected control '\(identifier)' to exist.",
            file: file, line: line
        )
        return el
    }

    /// Scroll the enclosing list until the control exists AND sits fully
    /// inside the unobscured content rect (below the nav bar, above the
    /// floating bottom toolbar), then return it for a genuine tap.
    /// `isHittable` alone is not sufficient: a row whose center sits under
    /// the floating toolbar still reports hittable, and a tap there lands
    /// on the toolbar instead of the row (measured: delivery row y
    /// 796-877 vs toolbar buttons y 803-841 on a 874pt window — the tap
    /// hit chrome, selection never moved). Like a user, this harness
    /// scrolls first and taps second.
    @discardableResult
    private func reveal(_ identifier: String, directionUp: Bool = true, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        // Phase 1: realize the row — SwiftUI lists only expose near-viewport
        // rows, so below-fold controls may not exist yet.
        var el = element(identifier)
        if !el.waitForExistence(timeout: 5) {
            for _ in 0..<6 {
                if directionUp { app.swipeUp() } else { app.swipeDown() }
                hold(1)
                el = element(identifier)
                if el.waitForExistence(timeout: 2) { break }
            }
        }
        // Phase 2: nudge until the whole row is clear of nav bar and toolbar.
        for _ in 0..<10 {
            el = element(identifier)
            guard el.exists else {
                if directionUp { app.swipeUp() } else { app.swipeDown() }
                hold(1)
                continue
            }
            let frame = el.frame
            let top = unobscuredTop()
            let bottom = unobscuredBottom()
            if frame.minY >= top && frame.maxY <= bottom && el.isHittable { return el }
            if frame.maxY > bottom {
                app.swipeUp()
            } else if frame.minY < top {
                app.swipeDown()
            } else if !el.isHittable {
                app.swipeUp()
            } else {
                return el
            }
            hold(1)
        }
        el = require(identifier, file: file, line: line)
        let frame = el.frame
        XCTAssertTrue(
            frame.minY >= unobscuredTop() && frame.maxY <= unobscuredBottom() && el.isHittable,
            "Control '\(identifier)' must sit fully clear of nav bar and toolbar before tapping (frame \(frame)).",
            file: file, line: line
        )
        return el
    }

    /// Lowest y covered by top navigation chrome; content must start below it.
    private func unobscuredTop() -> CGFloat {
        let nav = app.navigationBars.firstMatch
        if nav.exists { return nav.frame.maxY + 4 }
        return 140
    }

    /// Highest y covered by the floating bottom toolbar; content must end
    /// above it. Derived from the actual toolbar buttons on screen.
    private func unobscuredBottom() -> CGFloat {
        var top = CGFloat.greatestFiniteMagnitude
        for id in ["toolbar-map", "toolbar-preview", "toolbar-compare", "toolbar-report", "map-back", "map-across"] {
            let chrome = element(id)
            if chrome.exists { top = min(top, chrome.frame.minY) }
        }
        if top < CGFloat.greatestFiniteMagnitude { return top - 4 }
        let win = app.windows.firstMatch
        if win.exists { return win.frame.maxY - 120 }
        return 700
    }

    private func requireText(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let el = app.staticTexts[text]
        XCTAssertTrue(
            el.waitForExistence(timeout: 10),
            "Expected text '\(text)' on screen.",
            file: file, line: line
        )
    }

    /// LabeledContent rows expose one combined label ("Source identity,
    /// 76426ef75011"), so exact-match lookup needs the whole label.
    private func requireTextContaining(_ fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        let el = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
        XCTAssertTrue(
            el.waitForExistence(timeout: 10),
            "Expected text containing '\(fragment)' on screen.",
            file: file, line: line
        )
    }

    /// Scroll like a user until a below-fold proof line is realized, then
    /// hold it readable. No state is edited; scrolling only moves content.
    private func scrollToTextContaining(_ fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 {
            let el = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
            if el.waitForExistence(timeout: 2) { return }
            app.swipeUp()
            hold(1)
        }
        requireTextContaining(fragment, file: file, line: line)
    }

    /// Scroll back toward the top until a header line is realized again,
    /// so branch identities stay recoverable after a diff excursion.
    private func scrollDownToTextContaining(_ fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 {
            let el = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
            if el.waitForExistence(timeout: 2) { return }
            app.swipeDown()
            hold(1)
        }
        requireTextContaining(fragment, file: file, line: line)
    }

    /// Readable hold so recorded frames settle; the harness may pace genuine
    /// actions, it never fabricates progress or result states.
    private func hold(_ seconds: UInt32 = 3) {
        sleep(seconds)
    }

    private func shot(_ name: String) {
        let image = app.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Continuous STATE walkthrough (primary recording capture)

    /// One launch, no resets: question → accept queue-time → saved v1 →
    /// back → select delivery-time → preview → accept delivery-time →
    /// saved v2 → compare → reopen v1 → Historical report → return.
    /// Intent is carried by genuine taps, never by fresh launches.
    func testWalkthroughState() {
        app.launch()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))

        // S1 — the request and the question.
        requireText("Sample workspace")
        XCTAssertTrue(element("answer-queueTime").label.contains("Selected"))
        XCTAssertTrue(element("answer-deliveryTime").label.contains("Accepted"))
        hold(6)
        shot("walkthrough-opening")

        // S2 — selecting is not accepting; the explicit button decides.
        reveal("answer-deliveryTime").tap()
        hold(2)
        XCTAssertTrue(element("answer-deliveryTime").label.contains("Selected"))
        XCTAssertFalse(reveal("accept-selected").isEnabled)
        reveal("answer-queueTime", directionUp: false).tap()
        hold(2)
        XCTAssertTrue(reveal("accept-selected").isEnabled)
        element("accept-selected").tap()
        hold(2)
        XCTAssertTrue(element("answer-queueTime").label.contains("Accepted"))
        shot("walkthrough-accepted-queuetime")

        // S3 — map and saved program v1 with worker consequence + outcome.
        element("toolbar-map").tap()
        XCTAssertTrue(app.navigationBars["Decision Map"].waitForExistence(timeout: 10))
        hold(2)
        shot("walkthrough-map")
        reveal("map-program-v1").tap()
        XCTAssertTrue(app.navigationBars["Program v1"].waitForExistence(timeout: 10))
        requireText("Source identity, 76426ef75011")
        hold(3)
        shot("walkthrough-v1-source")
        scrollToTextContaining("Deliver trusts the enqueue-time snapshot: revoked access still exports.")
        hold(3)
        shot("walkthrough-v1-worker")
        scrollToTextContaining("Retained revoked_after_enqueue → exported (audit + release).")
        hold(3)
        shot("walkthrough-v1-outcome")

        // Back to the question with queue-time intent intact.
        app.navigationBars["Program v1"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Decision Map"].waitForExistence(timeout: 10))
        element("map-back").tap()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))
        XCTAssertTrue(element("answer-queueTime").label.contains("Accepted"))

        // S5a — select delivery-time, then preview before deciding.
        reveal("answer-deliveryTime").tap()
        hold(2)
        XCTAssertTrue(element("answer-deliveryTime").label.contains("Selected"))
        element("toolbar-preview").tap()
        XCTAssertTrue(app.navigationBars["Preview"].waitForExistence(timeout: 10))
        hold(1)
        app.swipeUp()
        requireText("9 required checks · 0 executed")
        hold(3)
        shot("walkthrough-preview")
        element("preview-close").tap()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))

        // S5b — explicit accept of delivery-time; then saved program v2.
        XCTAssertTrue(reveal("accept-selected").isEnabled)
        element("accept-selected").tap()
        hold(2)
        XCTAssertTrue(element("answer-deliveryTime").label.contains("Accepted"))
        shot("walkthrough-accepted-deliverytime")
        element("toolbar-map").tap()
        XCTAssertTrue(app.navigationBars["Decision Map"].waitForExistence(timeout: 10))
        reveal("map-program-v2").tap()
        XCTAssertTrue(app.navigationBars["Program v2"].waitForExistence(timeout: 10))
        requireText("Source identity, 61885a86f762")
        hold(3)
        shot("walkthrough-v2-source")
        scrollToTextContaining("re-checks access.Allowed")
        hold(3)
        shot("walkthrough-v2-worker")
        scrollToTextContaining("Retained revoked_after_enqueue → access_revoked (no events).")
        hold(3)
        shot("walkthrough-v2-outcome")

        // S4 — read-only compare of the two saved programs.
        app.navigationBars["Program v2"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Decision Map"].waitForExistence(timeout: 10))
        element("map-back").tap()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))
        element("toolbar-compare").tap()
        XCTAssertTrue(app.navigationBars["Compare"].waitForExistence(timeout: 10))
        requireText("v1 · request-time")
        requireText("v2 · delivery-time")
        hold(2)
        shot("walkthrough-compare-sides")
        scrollToTextContaining("Mode = \"delivery_time\"")
        hold(3)
        shot("walkthrough-compare-queue-diff")
        scrollDownToTextContaining("v1 · request-time")
        app.segmentedControls["compare-file-picker"].buttons["worker.go"].tap()
        hold(1)
        scrollToTextContaining("access.Allowed(job.TenantID, job.UserID)")
        hold(3)
        shot("walkthrough-compare-worker-diff")
        scrollDownToTextContaining("v1 · request-time")
        app.segmentedControls["compare-file-picker"].buttons["domain.go"].tap()
        hold(1)
        requireText("domain.go is unchanged between v1 and v2.")
        hold(2)
        shot("walkthrough-compare-domain")
        element("compare-close").tap()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))

        // S6 — cheap return: reopen v1 while delivery-time stays accepted,
        // then the report reads Historical for the viewed branch.
        element("toolbar-map").tap()
        XCTAssertTrue(app.navigationBars["Decision Map"].waitForExistence(timeout: 10))
        reveal("map-program-v1").tap()
        XCTAssertTrue(app.navigationBars["Program v1"].waitForExistence(timeout: 10))
        hold(3)
        shot("walkthrough-reopen-v1")
        app.navigationBars["Program v1"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Decision Map"].waitForExistence(timeout: 10))
        element("map-back").tap()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))
        XCTAssertTrue(element("answer-deliveryTime").label.contains("Accepted"))
        element("toolbar-report").tap()
        XCTAssertTrue(app.navigationBars["Report"].waitForExistence(timeout: 10))
        requireText("Historical")
        requireTextContaining("valid for this saved branch only")
        hold(3)
        shot("walkthrough-report-historical")
        app.navigationBars["Report"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))

        // S7 — close on the question; delivery-time still the intent.
        XCTAssertTrue(element("answer-deliveryTime").label.contains("Accepted"))
        hold(4)
        shot("walkthrough-closing")
    }

    // MARK: - Appendix capture (preview obligation + provenance)

    /// Dedicated appendix take: preview checks held readable, then the
    /// About sample summary held readable. No taps skipped, no scenes faked.
    func testAppendixTake() {
        app.launch()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))
        element("toolbar-preview").tap()
        XCTAssertTrue(app.navigationBars["Preview"].waitForExistence(timeout: 10))
        hold(1)
        app.swipeUp()
        requireText("9 required checks · 0 executed")
        requireTextContaining("three Go sources per program")
        hold(6)
        shot("appendix-preview-checks")
        element("preview-close").tap()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))
        app.buttons["About this sample"].tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 10))
        requireTextContaining("authored sample content only")
        hold(6)
        shot("appendix-about")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))
        hold(2)
    }

    // MARK: - Beat 1: opening owner question (no taps)

    func testBeat1Opening() {
        app.launch()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))
        let queue = require("answer-queueTime")
        XCTAssertTrue(queue.label.contains("Selected"), "Queue-time answer must read Selected at launch.")
        let delivery = require("answer-deliveryTime")
        XCTAssertTrue(delivery.label.contains("Accepted"), "Delivery-time answer must read Accepted at launch.")
        hold(6)
        shot("beat1-opening-question")
    }

    // MARK: - Beat 2: select is not accept; explicit accept decides

    func testBeat2SelectAccept() {
        app.launch()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))
        // Selecting the already-accepted delivery-time answer: Accept stays off.
        reveal("answer-deliveryTime").tap()
        hold(2)
        XCTAssertTrue(
            element("answer-deliveryTime").label.contains("Selected"),
            "Tapping a covered answer row must actually move selection."
        )
        XCTAssertFalse(
            reveal("accept-selected").isEnabled,
            "Accept must stay disabled when the selected answer is already accepted."
        )
        shot("beat2-selected-accepted")
        // Selecting queue-time enables Accept; tapping it accepts.
        reveal("answer-queueTime", directionUp: false).tap()
        hold(2)
        XCTAssertTrue(reveal("accept-selected").isEnabled, "Accept must enable for a newly selected answer.")
        element("accept-selected").tap()
        hold(2)
        XCTAssertTrue(
            element("answer-queueTime").label.contains("Accepted"),
            "Queue-time row must carry the Accepted caption after Accept."
        )
        XCTAssertFalse(element("accept-selected").isEnabled, "Accept must disable once selection equals intent.")
        shot("beat2-accepted-queuetime")
        hold(2)
    }

    // MARK: - Beat 3: map, saved program source, retained outcome

    func testBeat3MapAndProgram() {
        app.launch()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))
        reveal("accept-selected").tap() // Accept the pre-selected queue-time answer.
        hold(1)
        element("toolbar-map").tap()
        XCTAssertTrue(app.navigationBars["Decision Map"].waitForExistence(timeout: 10))
        hold(2)
        shot("beat3-map")
        reveal("map-program-v1").tap()
        XCTAssertTrue(app.navigationBars["Program v1"].waitForExistence(timeout: 10))
        // LabeledContent exposes one combined accessibility label.
        requireText("Source identity, 76426ef75011")
        hold(2)
        shot("beat3-program-v1-source")
        // Below the fold: the worker consequence and the retained outcome.
        scrollToTextContaining("Deliver trusts the enqueue-time snapshot: revoked access still exports.")
        hold(2)
        shot("beat3-program-v1-worker")
        scrollToTextContaining("Retained revoked_after_enqueue → exported (audit + release).")
        hold(2)
        shot("beat3-program-v1-outcome")
    }

    // MARK: - Beat 4: read-only compare, two files changed, domain unchanged

    func testBeat4Compare() {
        app.launch()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))
        element("toolbar-compare").tap()
        XCTAssertTrue(app.navigationBars["Compare"].waitForExistence(timeout: 10))
        // Both branch identities are on screen first: the diffs below mean
        // nothing without them.
        requireText("v1 · request-time")
        requireText("v2 · delivery-time")
        requireTextContaining("76426ef75011")
        requireTextContaining("61885a86f762")
        hold(2)
        shot("beat4-compare-sides")
        // The queue.go diff sits below both side cards: scroll to it.
        scrollToTextContaining("Mode = \"delivery_time\"")
        hold(2)
        shot("beat4-compare-queue-diff")
        // Back up so the picker is reachable, then the worker.go diff.
        scrollDownToTextContaining("v1 · request-time")
        app.segmentedControls["compare-file-picker"].buttons["worker.go"].tap()
        hold(1)
        scrollToTextContaining("access.Allowed(job.TenantID, job.UserID)")
        hold(2)
        shot("beat4-compare-worker-diff")
        // Recover both identities after the excursion, then the unchanged file.
        scrollDownToTextContaining("v1 · request-time")
        requireText("v2 · delivery-time")
        hold(1)
        shot("beat4-compare-sides-again")
        app.segmentedControls["compare-file-picker"].buttons["domain.go"].tap()
        hold(1)
        requireText("domain.go is unchanged between v1 and v2.")
        hold(2)
        shot("beat4-compare-domain")
        element("compare-close").tap()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))
    }

    // MARK: - Beat 5: report binding — Current vs Historical, intent untouched

    func testBeat5Report() {
        app.launch()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))
        element("toolbar-report").tap()
        XCTAssertTrue(app.navigationBars["Report"].waitForExistence(timeout: 10))
        // Fresh launch: viewed v1, latest accepted delivery-time → Historical.
        requireText("Historical")
        hold(2)
        shot("beat5-report-historical")
        app.segmentedControls["report-viewed-picker"].buttons["v2 · delivery-time"].tap()
        hold(1)
        requireText("Current")
        hold(2)
        shot("beat5-report-current")
    }

    // MARK: - Beat 6: cheap return — Across, reopen v1, Back, intent preserved

    func testBeat6CheapReturn() {
        app.launch()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))
        element("toolbar-map").tap()
        XCTAssertTrue(app.navigationBars["Decision Map"].waitForExistence(timeout: 10))
        element("map-across").tap() // Selection queue-time → delivery-time; accepts nothing.
        hold(2)
        shot("beat6-across")
        reveal("map-program-v1").tap()
        XCTAssertTrue(app.navigationBars["Program v1"].waitForExistence(timeout: 10))
        hold(2)
        // System back to the map, then the map's own Back to the question.
        app.navigationBars["Program v1"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Decision Map"].waitForExistence(timeout: 10))
        element("map-back").tap()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))
        // Reopening v1 changed nothing: delivery-time still accepted.
        XCTAssertTrue(
            element("answer-deliveryTime").label.contains("Accepted"),
            "Latest accepted intent must survive cheap branch traversal."
        )
        hold(2)
        shot("beat6-back-intent-preserved")
    }

    // MARK: - Beat 7: preview obligation + sample provenance

    func testBeat7PreviewAndAbout() {
        app.launch()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))
        element("toolbar-preview").tap()
        XCTAssertTrue(app.navigationBars["Preview"].waitForExistence(timeout: 10))
        hold(1)
        app.swipeUp() // Checks section sits below the medium-detent fold; scroll like a user.
        requireText("9 required checks · 0 executed")
        hold(3)
        shot("beat7-preview")
        element("preview-close").tap()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))
        app.buttons["About this sample"].tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 10))
        hold(3)
        shot("beat7-about")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 10))
    }
}
