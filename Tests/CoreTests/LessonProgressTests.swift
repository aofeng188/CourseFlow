import Foundation
import Testing
@testable import CourseKit

@Suite("连堂课进度与课程头像")
struct LessonProgressTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func lesson(_ minutes: [(Int, Int)]) -> Occurrence {
        Occurrence(id: "lesson", semesterID: UUID(), courseID: UUID(), ruleID: UUID(), originalDate: start, courseName: "高等数学", colorIndex: 0, location: "", teacher: "", week: 1,
                   segments: minutes.enumerated().map { TeachingSegment(start: at($1.0), end: at($1.1), periodNumber: $0 + 1) })
    }
    private func at(_ minute: Double) -> Date { start.addingTimeInterval(minute * 60) }
    private func at(_ minute: Int) -> Date { at(Double(minute)) }

    @Test func coversEverySegmentOfABackToBackLesson() throws {
        // 三节连堂：45 分钟一节，课间 10 分钟。
        let item = lesson([(0, 45), (55, 100), (110, 155)])
        let second = try #require(item.progress(at: at(77.5)))
        #expect(second.parts.map(\.fraction) == [1, 0.5, 0])
        #expect(second.parts.map(\.periodNumber) == [1, 2, 3])
        #expect(second.position == 2)
        #expect(abs(second.overall - 0.5) < 1e-9)
        #expect(second.end == at(155))
    }

    @Test func holdsStillDuringBreaksAndClampsOutsideTheLesson() throws {
        let item = lesson([(0, 45), (55, 100)])
        let onBreak = try #require(item.progress(at: at(50)))
        #expect(onBreak.parts.map(\.fraction) == [1, 0])
        #expect(onBreak.position == 2)
        #expect(onBreak.overall == 0.5)
        #expect(item.progress(at: at(-30))?.overall == 0)
        #expect(item.progress(at: at(-30))?.position == 1)
        #expect(item.progress(at: at(500))?.overall == 1)
        #expect(item.progress(at: at(500))?.position == 2)
    }

    @Test func weighsSegmentsByTheirLength() throws {
        let item = lesson([(0, 90), (100, 130)])
        let progress = try #require(item.progress(at: at(45)))
        #expect(progress.parts.map(\.weight) == [0.75, 0.25])
        #expect(progress.overall == 0.375)
        #expect(lesson([]).progress(at: start) == nil)
    }

    @Test func avatarIsOptionalInStoredCoursesAndBackups() throws {
        let semester = Semester(name: "秋季学期", firstMonday: ISO8601DateFormatter().date(from: "2026-09-07T00:00:00+08:00")!)
        // 旧版本保存的课程没有头像字段。
        let legacy = #"{"id":"\#(UUID().uuidString)","semesterID":"\#(semester.id.uuidString)","name":"高等数学","colorIndex":1,"notes":""}"#
        #expect(try JSONDecoder().decode(Course.self, from: Data(legacy.utf8)).avatar == nil)
        #expect(!String(decoding: try JSONEncoder().encode(Course(semesterID: semester.id, name: "高等数学")), as: UTF8.self).contains("avatar"))

        var course = Course(semesterID: semester.id, name: "体育", avatar: CourseAvatarStyle(symbol: "figure.run"))
        var snapshot = ScheduleSnapshot(semesters: [semester], courses: [course])
        #expect(try BackupCodec.decode(BackupCodec.encode(snapshot)).courses.first?.avatar == course.avatar)

        course.avatar = CourseAvatarStyle(image: Data(count: CourseAvatarStyle.maxImageBytes + 1))
        snapshot.courses = [course]
        #expect(throws: BackupError.self) { try BackupCodec.validate(snapshot) }
        course.avatar = CourseAvatarStyle(text: "高等数")
        snapshot.courses = [course]
        #expect(throws: BackupError.self) { try BackupCodec.validate(snapshot) }
    }
}
