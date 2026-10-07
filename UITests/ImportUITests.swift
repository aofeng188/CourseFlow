import XCTest

final class ImportUITests: XCTestCase {
    @MainActor func testPastedTimetableCanBeReviewedCommittedAndOpenedFromCourseList() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--demo"]
        app.launch()
        let courseName = "导入界面验收课"
        let original = "\(courseName) 周日 21:00-21:45 1-8周 地点:测试楼Z909 教师:测试老师"

        XCTAssertTrue(app.buttons["add-menu"].waitForExistence(timeout: 15))
        app.buttons["add-menu"].tap()
        app.buttons["导入课表或作息"].tap()
        XCTAssertTrue(app.navigationBars["导入课表"].waitForExistence(timeout: 5))
        let paste = app.buttons["import-paste"]
        scrollTo(paste, in: app)
        paste.tap()

        let editor = app.textViews["import-paste-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); editor.typeText(original)
        let recognize = app.buttons["import-paste-recognize"]
        XCTAssertTrue(recognize.isEnabled)
        recognize.tap()
        XCTAssertTrue(app.navigationBars["导入课表"].waitForExistence(timeout: 5))

        let draftCourse = app.staticTexts[courseName].firstMatch
        scrollTo(draftCourse, in: app)
        draftCourse.tap()
        XCTAssertTrue(app.navigationBars["核对课程"].waitForExistence(timeout: 5))
        let name = app.textFields["import-lesson-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, courseName)
        XCTAssertEqual(app.textFields["import-lesson-location"].value as? String, "测试楼Z909")
        let start = app.textFields["import-lesson-start"]
        scrollTo(start, in: app)
        XCTAssertEqual(start.value as? String, "21:00")
        XCTAssertEqual(app.textFields["import-lesson-end"].value as? String, "21:45")
        let weeks = app.textFields["import-lesson-weeks"]
        scrollTo(weeks, in: app)
        XCTAssertEqual(weeks.value as? String, "1-8 周")
        app.buttons["import-lesson-save"].tap()

        XCTAssertTrue(app.navigationBars["导入课表"].waitForExistence(timeout: 5))
        let commit = app.buttons["import-confirm"]
        scrollTo(commit, in: app)
        XCTAssertTrue(commit.isEnabled, "A complete course with explicit times should be ready to import.")
        commit.tap()
        XCTAssertTrue(app.buttons["week-picker"].waitForExistence(timeout: 8))
        app.tabBars.buttons["课程"].tap()
        XCTAssertTrue(app.navigationBars["课程"].waitForExistence(timeout: 5))
        let savedCourse = app.staticTexts[courseName].firstMatch
        scrollTo(savedCourse, in: app)
        savedCourse.tap()
        XCTAssertTrue(app.navigationBars["课程详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[courseName].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Pasted course imported and opened"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "Expected element to become reachable after scrolling: \(element)", file: file, line: line)
    }
}
