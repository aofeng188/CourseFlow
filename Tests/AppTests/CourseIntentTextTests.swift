import XCTest
import CourseKit
@testable import CourseFlow

final class CourseIntentTextTests: XCTestCase {
    private let data = SampleData.make(now: ISO8601DateFormatter().date(from: "2026-10-05T07:00:00+08:00")!)
    private var semester: Semester { data.semesters[0] }
    private var occurrences: [Occurrence] { ScheduleEngine.occurrences(snapshot: data, semesterID: semester.id) }
    private func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    /// The sample timetable has 高等数学 in periods 1–2 (08:00–09:40) on Mondays.
    func testNextCourseDescribesCurrentAndUpcomingLessons() {
        let before = CourseIntentText.nextCourse(at: at("2026-10-05T07:00:00+08:00"), occurrences: occurrences, semester: semester)
        XCTAssertEqual(before, "下一节课是「高等数学」，今天 08:00 开始，地点 明德楼 A301。")
        let during = CourseIntentText.nextCourse(at: at("2026-10-05T08:10:00+08:00"), occurrences: occurrences, semester: semester)
        XCTAssertEqual(during, "正在上「高等数学」，本节 08:45 下课，地点 明德楼 A301。")
        let onBreak = CourseIntentText.nextCourse(at: at("2026-10-05T08:50:00+08:00"), occurrences: occurrences, semester: semester)
        XCTAssertEqual(onBreak, "「高等数学」课间休息，08:55 继续上课，地点 明德楼 A301。")
    }

    func testNextCourseUsesSchoolTimeZoneAndRelativeDays() {
        // Sunday evening: the next lesson is Monday morning, reported in school time.
        let text = CourseIntentText.nextCourse(at: at("2026-10-04T22:00:00+08:00"), occurrences: occurrences, semester: semester)
        XCTAssertEqual(text, "下一节课是「高等数学」，明天 08:00 开始，地点 明德楼 A301。")
    }

    func testTodayListsLessonsInOrder() {
        let text = CourseIntentText.today(at: at("2026-10-05T12:00:00+08:00"), occurrences: occurrences, semester: semester)
        XCTAssertTrue(text.hasPrefix("今天有 2 节课：08:00 高等数学（明德楼 A301）；14:00 程序设计（信息楼 503）"), text)
        let saturday = CourseIntentText.today(at: at("2026-10-10T12:00:00+08:00"), occurrences: occurrences, semester: semester)
        XCTAssertEqual(saturday, "今天没有课，好好安排自己的时间。")
    }

    func testMissingSemesterGivesGuidance() {
        XCTAssertTrue(CourseIntentText.nextCourse(at: .now, occurrences: [], semester: nil).contains("还没有课表"))
        XCTAssertTrue(CourseIntentText.today(at: .now, occurrences: [], semester: nil).contains("还没有课表"))
    }
}
