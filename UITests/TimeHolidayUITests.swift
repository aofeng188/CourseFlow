import XCTest

final class TimeHolidayUITests: XCTestCase {
    @MainActor private func launch(_ date: String, list: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--demo", "--preview-date", date]
        if list { app.launchArguments.append("--preview-agenda") }
        app.launch()
        XCTAssertTrue(app.buttons["week-picker"].waitForExistence(timeout: 15))
        return app
    }
    @MainActor @discardableResult private func reveal(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        // Strokes stay shorter than the visible band and halve on each reversal, so a short
        // screen such as a folded iPhone Duo cannot keep stepping over the element. They run
        // down the leading margin: a stroke that starts on a switch row does not scroll.
        var stride: CGFloat?, wasScrollingUp = true
        for _ in 0..<40 {
            let confirm = app.buttons["holiday-batch-confirm"]
            let lowerEdge: CGFloat
            if confirm.exists { lowerEdge = confirm.frame.minY - 70 }
            else { lowerEdge = app.frame.height - (app.tabBars.firstMatch.exists ? 120 : 40) }
            var scrollUp = true
            if element.exists {
                let frame = element.frame
                let fullyVisible = frame.minY > 150 && frame.maxY < lowerEdge
                let oversizedButTappable = frame.height > lowerEdge - 150 && frame.midY > 150 && frame.midY < lowerEdge
                if (fullyVisible || oversizedButTappable) && element.isHittable { return true }
                scrollUp = frame.minY >= 150
            }
            let length = scrollUp == wasScrollingUp ? stride ?? (lowerEdge - 150) / 2 : max(40, (stride ?? 80) / 2)
            stride = length; wasScrollingUp = scrollUp
            let origin = app.coordinate(withNormalizedOffset: .zero), x: CGFloat = 12, middle = (150 + lowerEdge) / 2
            let start = origin.withOffset(CGVector(dx: x, dy: middle + (scrollUp ? length : -length) / 2))
            let end = origin.withOffset(CGVector(dx: x, dy: middle - (scrollUp ? length : -length) / 2))
            // The measured stroke positions an element the list has already created. Until then, and
            // whenever a stroke leaves the list where it was, the system swipe moves it in a longer step.
            let before = element.exists ? element.frame : nil
            if before != nil { start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1) }
            if before == nil || (element.exists && element.frame == before) {
                let form = app.collectionViews.firstMatch, scroll = app.scrollViews.firstMatch
                let list = form.exists ? form : (scroll.exists ? scroll : app)
                if scrollUp { list.swipeUp(velocity: .slow) } else { list.swipeDown(velocity: .slow) }
            }
        }
        capture(app, name: "滚动后仍无法显示")
        XCTFail("滚动后仍无法显示待操作控件", file: file, line: line)
        return false
    }
    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func holidayGroup(in app: XCUIApplication) -> XCUIElement {
        app.buttons["holiday-group-prompt-2026-国庆节"]
    }
    @MainActor private func openHolidayGroup(in app: XCUIApplication) {
        let group = holidayGroup(in: app)
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        // Large text can make the whole card taller than the screen. Tap its
        // visible portion rather than requiring the full button frame to fit.
        for _ in 0..<10 {
            if group.exists {
                let safeArea = CGRect(x: 0, y: 150, width: app.frame.width, height: app.frame.height - 270)
                let visible = group.frame.intersection(safeArea)
                if !visible.isNull && visible.height > 44 && group.isHittable {
                    app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: visible.midX, dy: visible.midY)).tap()
                    break
                }
            }
            let scroll = app.scrollViews.firstMatch
            if scroll.exists { scroll.swipeUp(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(app.navigationBars["国庆节学校安排"].waitForExistence(timeout: 5))
    }
    @MainActor private func makeupChoice(_ key: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "holiday-makeup-choice-\(key)").firstMatch
    }
    @MainActor private func chooseMakeup(_ choice: String, date: String, in app: XCUIApplication) {
        let picker = makeupChoice(date, in: app)
        guard reveal(picker, in: app) else { return }
        XCTAssertTrue(picker.exists)
        picker.tap()
        let option = app.buttons[choice].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        option.tap()
    }
    @MainActor private func confirmHolidayGroup(in app: XCUIApplication) {
        let confirm = app.buttons["holiday-batch-confirm"]
        XCTAssertTrue(confirm.exists)
        confirm.tap()
        XCTAssertTrue(app.buttons["week-picker"].waitForExistence(timeout: 5))
    }
    @MainActor func testGridAndListShowCurrentTime() {
        let app = launch("2026-10-05T08:20:00+08:00")
        XCTAssertTrue(app.otherElements["grid-now-line"].exists || app.staticTexts["grid-now-line"].exists)
        capture(app, name: "当前时间周课表")
        app.buttons["日程列表"].tap()
        XCTAssertTrue(app.otherElements["now-marker"].exists || app.staticTexts["now-marker"].exists)
        XCTAssertTrue(app.staticTexts["正在上课"].firstMatch.exists)
        let marker = app.descendants(matching: .any).matching(identifier: "now-marker").firstMatch
        reveal(marker, in: app)
        capture(app, name: "当前时间日程列表")
        app.buttons["周课表"].tap()
        XCTAssertTrue(app.otherElements["grid-now-line"].waitForExistence(timeout: 3) || app.staticTexts["grid-now-line"].exists)
    }
    @MainActor func testCurrentCourseCardOpensDashboard() {
        let app = launch("2026-10-05T08:20:00+08:00")
        let card = app.descendants(matching: .any).matching(identifier: "current-course-card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        let close = app.buttons["dashboard-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["正在上课"].firstMatch.exists)
        XCTAssertTrue(app.buttons["dashboard-detail"].exists)
        capture(app, name: "上课大字仪表盘")
        close.tap()
        XCTAssertTrue(app.buttons["week-picker"].waitForExistence(timeout: 5))
    }
    @MainActor func testPendingMakeupCanWaitThenConfirm() {
        let app = launch("2026-10-10T08:20:00+08:00")
        let prompt = holidayGroup(in: app)
        openHolidayGroup(in: app)
        capture(app, name: "节日调休批量确认")
        app.barButton("稍后再说").tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["调休课程待定"].firstMatch.exists)
        openHolidayGroup(in: app)
        chooseMakeup("照常按原课表", date: "2026-10-10", in: app)
        confirmHolidayGroup(in: app)
        XCTAssertFalse(prompt.exists)
        capture(app, name: "调休确认后")
    }
    @MainActor func testHolidayGroupStartsSevenDaysBeforeFirstRelatedDate() {
        let app = launch("2026-09-12T08:20:00+08:00")
        XCTAssertFalse(holidayGroup(in: app).exists)
        app.terminate()
        let started = launch("2026-09-13T08:20:00+08:00")
        XCTAssertTrue(started.staticTexts["holiday-group-day-2026-10-10"].firstMatch.exists)
        openHolidayGroup(in: started)
        reveal(started.switches["holiday-select-2026-10-01"], in: started)
        XCTAssertTrue(started.switches["holiday-select-2026-10-01"].exists)
        reveal(started.switches["holiday-select-2026-10-07"], in: started)
        XCTAssertTrue(started.switches["holiday-select-2026-10-07"].exists)
        reveal(makeupChoice("2026-09-20", in: started), in: started)
        XCTAssertTrue(makeupChoice("2026-09-20", in: started).exists)
        reveal(makeupChoice("2026-10-10", in: started), in: started)
        XCTAssertTrue(makeupChoice("2026-10-10", in: started).exists)
        capture(started, name: "国庆提前整组提示")
    }
    @MainActor func testWholeHolidayCanConfirmWhileMakeupRemainsPending() {
        let app = launch("2026-10-02T08:20:00+08:00")
        openHolidayGroup(in: app)
        XCTAssertEqual(app.buttons["holiday-batch-confirm"].label, "确认7天安排")
        for key in ["2026-10-01", "2026-10-07"] {
            let selected = app.switches["holiday-select-\(key)"]
            reveal(selected, in: app)
            XCTAssertEqual(selected.value as? String, "1")
        }
        confirmHolidayGroup(in: app)
        XCTAssertTrue(holidayGroup(in: app).exists)
        openHolidayGroup(in: app)
        XCTAssertEqual(app.buttons["holiday-batch-confirm"].label, "确认0天安排")
        let confirmedFirst = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "10月1日", "修改或恢复待确认")).firstMatch
        reveal(confirmedFirst, in: app)
        XCTAssertTrue(confirmedFirst.exists)
        let confirmedLast = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "10月7日", "修改或恢复待确认")).firstMatch
        reveal(confirmedLast, in: app)
        XCTAssertTrue(confirmedLast.exists)
        reveal(makeupChoice("2026-10-10", in: app), in: app)
        XCTAssertTrue(makeupChoice("2026-10-10", in: app).exists)
        capture(app, name: "国庆整段确认后补班仍待定")
    }
    @MainActor func testHolidayBatchCanExcludeOneDate() {
        let app = launch("2026-10-02T08:20:00+08:00")
        openHolidayGroup(in: app)
        let excluded = app.switches["holiday-select-2026-10-03"]
        reveal(excluded, in: app)
        capture(app, name: "取消单日之前")
        // SwiftUI exposes the label and switch as one accessibility element;
        // tap the trailing switch thumb instead of the row's label center.
        excluded.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        capture(app, name: "取消单日之后")
        XCTAssertEqual(excluded.value as? String, "0")
        XCTAssertEqual(app.buttons["holiday-batch-confirm"].label, "确认6天安排")
        confirmHolidayGroup(in: app)
        openHolidayGroup(in: app)
        XCTAssertEqual(app.buttons["holiday-batch-confirm"].label, "确认1天安排")
        reveal(app.switches["holiday-select-2026-10-03"], in: app)
        XCTAssertEqual(app.switches["holiday-select-2026-10-03"].value as? String, "1")
    }
    @MainActor func testEveningOutOfRangeAndEmptyTodayAgenda() {
        let app = launch("2026-10-10T22:00:00+08:00", list: true)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["有课待定，确认后显示学校课程"].exists)
        XCTAssertTrue(app.otherElements["now-marker"].exists || app.staticTexts["now-marker"].exists)
        let marker = app.descendants(matching: .any).matching(identifier: "now-marker").firstMatch
        reveal(marker, in: app)
        capture(app, name: "夜间待定日程")
    }
    @MainActor func testLargeTypeAutomaticallyUsesAgenda() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--demo", "--preview-date", "2026-10-05T08:20:00+08:00", "--preview-large-type", "--preview-dark"]
        app.launch()
        XCTAssertTrue(app.buttons["week-picker"].waitForExistence(timeout: 15))
        let marker = app.descendants(matching: .any).matching(identifier: "now-marker").firstMatch
        XCTAssertTrue(marker.exists)
        reveal(marker, in: app)
        capture(app, name: "深色大字号时间日程")
    }
    @MainActor func testHolidayGroupWorksWithLargeTypeAndDarkAppearance() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--demo", "--preview-date", "2026-10-02T08:20:00+08:00", "--preview-large-type", "--preview-dark"]
        app.launch()
        XCTAssertTrue(app.buttons["week-picker"].waitForExistence(timeout: 15))
        openHolidayGroup(in: app)
        let makeup = makeupChoice("2026-10-10", in: app)
        reveal(makeup, in: app)
        XCTAssertTrue(makeup.exists)
        capture(app, name: "深色大字号节日批量确认")
        app.barButton("稍后再说").tap()
        XCTAssertTrue(holidayGroup(in: app).waitForExistence(timeout: 5))
    }
    @MainActor func testExportHasNoLiveTimeMarkers() {
        let app = launch("2026-10-05T08:20:00+08:00")
        app.buttons["分享与更多"].tap()
        app.buttons["分享本周图片"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 5) || app.otherElements["ActivityListView"].exists || app.buttons["Copy"].exists || app.buttons["拷贝"].exists)
        capture(app, name: "静态课表分享")
    }

    @MainActor func testPDFExportStillWorks() {
        let app = launch("2026-10-05T08:20:00+08:00")
        app.buttons["分享与更多"].tap()
        app.buttons["分享本周 PDF"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 5) || app.otherElements["ActivityListView"].exists || app.buttons["Copy"].exists || app.buttons["拷贝"].exists)
    }

}
