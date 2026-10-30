import XCTest

/// Read-only recording driver for the approved A → B → historical A
/// walkthrough. Resumes saved session ad6186198e7d and traverses its
/// retained evidence through genuine product controls with generous
/// legibility holds, while an external simctl recorder captures the
/// moving footage. No import/accept/generate/check/commit/push/observe
/// is touched; source/diff loads are read-only GETs. Holds are plain
/// sleeps on live UI (reviewer reading time), printed as BEAT markers
/// for the edit time-mapping.
final class WorkbenchRecordingBeatsTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func stamp(_ tag: String) {
        print("RECORD-BEAT \(tag) t=\(Date().timeIntervalSince1970)")
    }

    @discardableResult
    private func require(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let el = element(identifier)
        XCTAssertTrue(el.waitForExistence(timeout: 15),
                      "Expected control '\(identifier)' to exist.", file: file, line: line)
        return el
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

    private func setResumeField(to value: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let field = reveal("live-resume-id", file: file, line: line)
        let current = (element("live-resume-id").value as? String) ?? ""
        if current == value { return }
        field.tap()
        sleep(2)
        field.doubleTap()
        sleep(1)
        field.typeText(value)
        let actual = (element("live-resume-id").value as? String) ?? ""
        XCTAssertEqual(actual, value, "Resume field must read back exactly.", file: file, line: line)
        let ret = app.keyboards.buttons["Return"]
        for _ in 0..<10 {
            if !app.keyboards.firstMatch.exists { break }
            if ret.exists && ret.isHittable { ret.tap(); break }
            sleep(1)
        }
        app.navigationBars.firstMatch.tap()
        sleep(2)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Keyboard must dismiss.", file: file, line: line)
    }

    private func selectWorkerSource(file: StaticString = #filePath, line: UInt = #line) {
        reveal("live-source-picker", file: file, line: line).tap()
        sleep(1)
        // Scope to the open menu's item: loaded source/path labels can
        // also expose "worker.go" and make an unscoped tap ambiguous.
        let menuHit = app.descendants(matching: .menuItem)["worker.go"]
        let buttonHit = app.buttons["worker.go"]
        var tapped = false
        for _ in 0..<10 {
            if menuHit.exists && menuHit.isHittable { menuHit.tap(); tapped = true; break }
            if buttonHit.exists && buttonHit.isHittable { buttonHit.tap(); tapped = true; break }
            sleep(1)
        }
        XCTAssertTrue(tapped, "Menu item 'worker.go' must be tappable.", file: file, line: line)
        sleep(1)
        XCTAssertTrue(expose("live-source-path", file: file, line: line).label.contains("queued/worker.go"))
    }

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
    }

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

    private func currentMark(_ name: String) {
        print("CURRENT-UI-BEAT \(name) \(Date().timeIntervalSince1970)")
    }

    private func currentLocate(_ id: String, up: Bool = true) -> XCUIElement {
        for _ in 0..<28 {
            let el = app.descendants(matching: .any).matching(identifier: id).firstMatch
            if el.exists {
                let frame = el.frame
                let top = app.navigationBars.firstMatch.frame.maxY + 8
                let bottom = app.frame.maxY - 90
                if frame.midY > top && frame.midY < bottom && el.isHittable { return el }
                if frame.midY < top { app.swipeDown() } else { app.swipeUp() }
            } else if up { app.swipeUp() } else { app.swipeDown() }
            sleep(1)
        }
        XCTFail("Could not reach \(id)")
        return app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func currentWaitBuilt(_ name: String) {
        let deadline = Date().addingTimeInterval(480)
        while Date() < deadline {
            let narrative = element("live-construction-narrative")
            if narrative.exists {
                let text = narrative.label
                XCTAssertFalse(text.contains("Construction failed"), text)
                if text.contains("\(name) is ready to inspect") { return }
            }
            sleep(2)
        }
        XCTFail("Construction \(name) did not complete")
    }

    private func currentWaitLabel(_ id: String, contains text: String, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let el = app.descendants(matching: .any).matching(identifier: id).firstMatch
            if el.exists && el.label.contains(text) { return }
            sleep(1)
        }
        XCTFail("Expected \(id) to contain \(text)")
    }

    func testRecordCurrentUIRun() {
        app.launch()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 15))
        currentMark("START")
        sleep(7)
        app.buttons["toolbar-live"].tap()
        XCTAssertTrue(app.navigationBars["Live Workbench"].waitForExistence(timeout: 15))
        currentLocate("live-connect").tap()
        currentWaitLabel("live-status", contains: "Imported", timeout: 60)
        currentMark("IMPORTED")
        sleep(4)
        currentLocate("live-construct-queue_time").tap()
        currentMark("A_BEGIN")
        currentWaitBuilt("A")
        currentMark("A_READY")
        sleep(7)
        currentLocate("live-operations-toggle").tap()
        let checkA = currentLocate("live-check")
        XCTAssertTrue(checkA.isEnabled)
        currentMark("A_CHECK_TAP")
        checkA.tap()
        currentWaitLabel("live-check", contains: "Checked", timeout: 90)
        XCTAssertFalse(app.buttons["live-check"].isEnabled)
        currentMark("A_CHECKED")
        sleep(6)
        let resultA = currentLocate("live-consequence", up: false)
        XCTAssertTrue(resultA.label.contains("customer records package was still released"))
        currentMark("A_RESULT")
        sleep(6)
        currentLocate("live-construct-delivery_time", up: false).tap()
        currentMark("B_BEGIN")
        currentWaitBuilt("B")
        currentMark("B_READY")
        sleep(7)
        let checkB = currentLocate("live-check")
        XCTAssertTrue(checkB.isEnabled)
        currentMark("B_CHECK_TAP")
        checkB.tap()
        currentWaitLabel("live-check", contains: "Checked", timeout: 90)
        XCTAssertFalse(app.buttons["live-check"].isEnabled)
        currentMark("B_CHECKED")
        sleep(6)
        let resultB = currentLocate("live-consequence", up: false)
        XCTAssertTrue(resultB.label.contains("Delivery was blocked"))
        currentMark("B_RESULT")
        sleep(6)
        currentLocate("live-candidate-A").tap()
        let historical = currentLocate("live-view-context", up: false)
        XCTAssertTrue(historical.label.contains("Viewing: A (historical)"))
        currentMark("HISTORICAL_A")
        sleep(5)
        currentLocate("live-return-B", up: false).tap()
        XCTAssertTrue(element("live-view-context").label.contains("Viewing: B (current)"))
        currentMark("RETURN_B")
        sleep(7)
        currentMark("END")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Current B result"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testCompletedOperationsPresentationReadOnly() {
        app.launch()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 15))
        element("toolbar-live").tap()
        XCTAssertTrue(app.navigationBars["Live Workbench"].waitForExistence(timeout: 15))
        setResumeField(to: "c683011877e7")
        expose("live-resume").tap()
        waitStatus(containing: "Resumed session c6830118", timeout: 60)
        expose("live-candidate-B").tap()
        _ = expose("live-operations-toggle")
        let toggle = app.buttons["live-operations-toggle"].firstMatch
        XCTAssertTrue(toggle.label.contains("on B"))
        toggle.tap()
        let check = expose("live-check")
        XCTAssertEqual(check.label, "Checked")
        XCTAssertFalse(check.isEnabled)
        XCTAssertEqual(check.value as? String, "Completed successfully")
        XCTAssertTrue(expose("live-commit").isEnabled)
        XCTAssertFalse(expose("live-push").isEnabled)
        XCTAssertFalse(expose("live-observe").isEnabled)
        let screen = app.debugDescription
        XCTAssertFalse(screen.contains("azure_openai"))
        XCTAssertFalse(screen.contains("Retained generator:"))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Completed check is green and disabled"
        image.lifetime = .keepAlways
        add(image)
    }

    func testRecordingBeatsReadOnly() {
        app.launch()
        XCTAssertTrue(app.navigationBars["CCPA Records Request"].waitForExistence(timeout: 15))
        element("toolbar-live").tap()
        XCTAssertTrue(app.navigationBars["Live Workbench"].waitForExistence(timeout: 15))
        XCTAssertTrue(element("live-question").waitForExistence(timeout: 15))
        stamp("OPEN-QUESTION")
        sleep(6)

        // Resume the saved session (read-only).
        setResumeField(to: "ad6186198e7d")
        reveal("live-resume").tap()
        waitStatus(containing: "Resumed session ad618619", timeout: 60)
        XCTAssertTrue(expose("live-session").label.contains("ad6186198e7d"))
        XCTAssertTrue(expose("live-answer-delivery_time").label.contains("Accepted"))
        stamp("RESUMED")
        sleep(6)

        // BEAT A: first retained implementation, queue-time guard, released.
        reveal("live-candidate-A").tap()
        sleep(2)
        XCTAssertTrue(expose("live-view-context").label.contains("Viewing: A (historical)"))
        XCTAssertTrue(expose("live-consequence").label.contains("The customer records package was still released"))
        selectWorkerSource()
        reveal("live-load-source").tap()
        XCTAssertTrue(element("live-source-meta").waitForExistence(timeout: 30))
        XCTAssertTrue(element("live-source-meta").label.contains("A|queued/worker.go"))
        XCTAssertTrue(expose("live-guard-excerpt").label.contains("if !job.PermissionSnapshot {"))
        stamp("A-GUARD")
        sleep(14)
        XCTAssertTrue(expose("live-outcome").label.contains("exported"))
        XCTAssertTrue(expose("live-commit-sha").label.contains("5adf3fa8626f"))
        XCTAssertTrue(expose("live-run-conclusion").label.contains("40535341214"))
        stamp("A-PROOF")
        sleep(10)

        // BEAT B: delivery-time revision, live guard, blocked.
        reveal("live-candidate-B").tap()
        sleep(2)
        XCTAssertTrue(expose("live-view-context").label.contains("Viewing: B (current)"))
        XCTAssertTrue(expose("live-map-B").label.contains("parent Candidate A"))
        XCTAssertTrue(expose("live-consequence").label.contains("Delivery was blocked; nothing was released"))
        selectWorkerSource()
        reveal("live-load-source").tap()
        XCTAssertTrue(element("live-source-meta").waitForExistence(timeout: 30))
        XCTAssertTrue(element("live-source-meta").label.contains("B|queued/worker.go"))
        XCTAssertTrue(expose("live-guard-excerpt").label.contains("if !access.Allowed(job.TenantID, job.UserID) {"))
        stamp("B-GUARD")
        sleep(12)
        reveal("live-load-diff").tap()
        XCTAssertTrue(element("live-diff-meta").waitForExistence(timeout: 30))
        XCTAssertTrue(element("live-diff-meta").label.contains("candidate B"))
        stamp("B-DIFF")
        sleep(10)
        XCTAssertTrue(expose("live-outcome").label.contains("access_revoked"))
        XCTAssertTrue(expose("live-commit-sha").label.contains("4bdb6c0cc000"))
        XCTAssertTrue(expose("live-run-conclusion").label.contains("40543004225"))
        stamp("B-PROOF")
        sleep(8)

        // BEAT historical A under accepted B: combined viewport, then return.
        reveal("live-view-A").tap()
        sleep(2)
        XCTAssertTrue(expose("live-view-context").label.contains(
            "Accepted: delivery-time · Viewing: A (historical)"))
        alignEvidenceTop()
        XCTAssertTrue(expose("live-return-B").exists)
        XCTAssertTrue(expose("live-consequence").label.contains("The customer records package was still released"))
        stamp("HIST-A")
        sleep(14)
        element("live-return-B").tap()
        sleep(2)
        XCTAssertTrue(expose("live-view-context").label.contains(
            "Accepted: delivery-time · Viewing: B (current)"))
        alignEvidenceTop()
        XCTAssertTrue(expose("live-consequence").label.contains("Delivery was blocked; nothing was released"))
        stamp("RETURN-B")
        sleep(10)

        // Proof holds and close on current B.
        XCTAssertTrue(expose("live-commit-sha").label.contains("4bdb6c0cc000"))
        XCTAssertTrue(expose("live-run-conclusion").label.contains("40543004225"))
        XCTAssertTrue(expose("live-counts").label.contains("2 candidates"))
        XCTAssertTrue(expose("live-counts").label.contains("2 commits"))
        stamp("CLOSE")
        sleep(8)
    }
}
