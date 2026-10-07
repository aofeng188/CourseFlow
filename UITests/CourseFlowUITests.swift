import XCTest

final class CourseFlowUITests: XCTestCase {
    @MainActor func testEnableNotifications() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--demo"]; app.launch()
        app.tabBars.buttons["设置"].tap()
        let toggle = app.switches["上课提醒"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.value as? String != "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for _ in 0..<6 {
                let choices = [app.alerts.buttons["允许"], app.alerts.buttons["Allow"], springboard.buttons["允许"], springboard.buttons["Allow"]]
                if let allow = choices.first(where: { $0.exists }) { allow.tap(); break }
                if toggle.value as? String == "1" { break }
                _ = app.alerts.firstMatch.waitForExistence(timeout: 1)
            }
        }
        let enabled = NSPredicate(format: "value == '1'")
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: toggle)], timeout: 5)
        if result != .completed {
            print("NOTIFICATION UI: \(app.debugDescription)")
            print("SPRINGBOARD UI: \(XCUIApplication(bundleIdentifier: "com.apple.springboard").debugDescription)")
            let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Notification permission failure"; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertEqual(result, .completed)
    }
    @MainActor func testWelcomeAndSampleTimetable() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.buttons["setup-semester"].waitForExistence(timeout: 15))
        app.buttons["load-example"].tap()
        XCTAssertTrue(app.buttons["week-picker"].waitForExistence(timeout: 10))
        app.buttons["week-picker"].tap()
        XCTAssertTrue(app.navigationBars["选择教学周"].waitForExistence(timeout: 3))
        app.buttons["完成"].tap()
        app.tabBars.buttons["课程"].tap()
        XCTAssertTrue(app.navigationBars["课程"].waitForExistence(timeout: 3))
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.staticTexts["学期与作息"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Settings"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testCreateSemesterAndManualCourseEntryPoint() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting"]; app.launch()
        app.buttons["setup-semester"].tap()
        let field = app.textFields["semester-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.buttons["save-semester"].tap()
        XCTAssertTrue(app.buttons["week-picker"].waitForExistence(timeout: 10))
        app.buttons["add-menu"].tap()
        app.buttons["手动添加课程"].tap()
        XCTAssertTrue(app.navigationBars["添加课程"].waitForExistence(timeout: 5) || app.navigationBars["新建课程"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Course editor"; attachment.lifetime = .keepAlways; add(attachment)
        let name = app.textFields["course-name"]
        name.tap(); name.typeText("验收测试课程")
        app.buttons["save-course"].tap()
        XCTAssertTrue(app.buttons["week-picker"].waitForExistence(timeout: 5))
        app.tabBars.buttons["课程"].tap()
        XCTAssertTrue(app.staticTexts["验收测试课程"].waitForExistence(timeout: 5))
        app.staticTexts["验收测试课程"].tap()
        XCTAssertTrue(app.navigationBars["课程详情"].waitForExistence(timeout: 5))
    }
}
