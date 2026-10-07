import XCTest

final class AIImportUITests: XCTestCase {
    @MainActor func testAIJSONCanBeReviewedEditedCommittedAndOpenedFromCourseList() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--demo"]
        app.launch()
        let originalName = "AI导入验收课"
        let editedName = "AI导入验收课（已核对）"
        let editedLocation = "更正楼 Z910"
        let json = #"{"format":"courseflow.ai","version":1,"kind":"timetable","sourceName":"测试","lessons":[{"name":"AI导入验收课","weekday":7,"weeks":"1-8","periods":null,"start":"21:00","end":"24:00","location":"测试楼Z909","teacher":"AI测试教师","source":"原文","warnings":[]}],"periods":[],"warnings":[]}"#

        XCTAssertTrue(app.buttons["add-menu"].waitForExistence(timeout: 15))
        app.buttons["add-menu"].tap()
        app.buttons["导入课表或作息"].tap()
        XCTAssertTrue(app.navigationBars["导入课表"].waitForExistence(timeout: 5))
        let entry = app.buttons["import-ai"]
        scrollTo(entry, in: app)
        entry.tap()
        XCTAssertTrue(app.navigationBars["AI 文本导入"].waitForExistence(timeout: 5))
        let copyPrompt = app.buttons["ai-import-copy-prompt"]
        scrollTo(copyPrompt, in: app)
        XCTAssertTrue(copyPrompt.isEnabled)
        attachScreenshot(app, named: "AI import instructions and copy prompt")

        let editor = app.textViews["ai-import-text"]
        scrollTo(editor, in: app)
        editor.tap()
        editor.typeText(json)
        let review = app.buttons["ai-import-review"]
        XCTAssertTrue(review.isEnabled)
        review.tap()
        XCTAssertTrue(app.navigationBars["导入课表"].waitForExistence(timeout: 8))
        let draftCourse = app.staticTexts[originalName].firstMatch
        scrollTo(draftCourse, in: app)
        draftCourse.tap()
        XCTAssertTrue(app.navigationBars["核对课程"].waitForExistence(timeout: 5))

        let name = app.textFields["import-lesson-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, originalName)
        let location = app.textFields["import-lesson-location"]
        XCTAssertEqual(location.value as? String, "测试楼Z909")
        XCTAssertEqual(app.textFields["授课教师（选填）"].value as? String, "AI测试教师")
        replaceText(in: name, with: editedName)
        replaceText(in: location, with: editedLocation)
        let start = app.textFields["import-lesson-start"]
        scrollTo(start, in: app)
        XCTAssertEqual(start.value as? String, "21:00")
        XCTAssertEqual(app.textFields["import-lesson-end"].value as? String, "24:00")
        let weeks = app.textFields["import-lesson-weeks"]
        scrollTo(weeks, in: app)
        XCTAssertEqual(weeks.value as? String, "1-8 周")
        app.buttons["import-lesson-save"].tap()

        XCTAssertTrue(app.navigationBars["导入课表"].waitForExistence(timeout: 5))
        let commit = app.buttons["import-confirm"]
        scrollTo(commit, in: app)
        XCTAssertTrue(commit.isEnabled)
        commit.tap()
        XCTAssertTrue(app.buttons["week-picker"].waitForExistence(timeout: 8))
        app.tabBars.buttons["课程"].tap()
        XCTAssertTrue(app.navigationBars["课程"].waitForExistence(timeout: 5))
        let savedCourse = app.staticTexts[editedName].firstMatch
        scrollTo(savedCourse, in: app)
        XCTAssertFalse(app.staticTexts[originalName].exists)
        savedCourse.tap()
        XCTAssertTrue(app.navigationBars["课程详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[editedName].exists)
        scrollTo(app.staticTexts[editedLocation].firstMatch, in: app)
        attachScreenshot(app, named: "AI course reviewed edited and saved")
    }

    @MainActor private func replaceText(in field: XCUIElement, with text: String) {
        let existing = field.value as? String ?? ""
        field.tap()
        // Tap the trailing blank area to position the insertion point after the value.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + text)
        XCTAssertEqual(field.value as? String, text)
    }

    @MainActor private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            // A full-screen flick can skip a field while the keyboard covers it.
            // Use a short stroke in the visible form, above the keyboard.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.52))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.32))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.exists && element.isHittable, "Expected element to become reachable after scrolling: \(element)", file: file, line: line)
    }

    @MainActor private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
