import Foundation
import Testing
@testable import CourseKit

@Suite("调休目标作息验证")
struct DayOverrideValidationTests {
    private func fixture() -> ScheduleSnapshot {
        let semester = Semester(firstMonday: ISO8601DateFormatter().date(from: "2026-09-14T00:00:00+08:00")!, weekCount: 4)
        let course = Course(semesterID: semester.id, name: "大学物理")
        let rule = MeetingRule(courseID: course.id, weeks: [1], periodNumbers: [1, 2])
        let bell = BellSchedule(semesterID: semester.id, effectiveFrom: semester.firstMonday, periods: [Period(number: 1, startMinute: 480, endMinute: 525), Period(number: 2, startMinute: 535, endMinute: 580)], isConfirmed: true)
        return ScheduleSnapshot(semesters: [semester], bellSchedules: [bell], courses: [course], rules: [rule])
    }

    @Test func preventsEmptyPreviewWhenTargetPredatesKnownBellSchedule() {
        var data = fixture(); let semester = data.semesters[0]
        let target = semester.calendar.date(byAdding: .day, value: -2, to: semester.firstMonday)!
        let change = DayOverride(semesterID: semester.id, date: target, followsDate: semester.firstMonday)
        #expect(DraftValidator.issues(for: change, snapshot: data).contains { $0.contains("作息") })
        data.dayOverrides = [change]
        #expect(throws: (any Error).self) { try BackupCodec.validate(data) }
    }

    @Test func earlierConfirmedBellScheduleMakesBeforeTermMakeupValid() throws {
        var data = fixture(); let semester = data.semesters[0]
        let target = semester.calendar.date(byAdding: .day, value: -2, to: semester.firstMonday)!
        data.bellSchedules[0].effectiveFrom = target
        let change = DayOverride(semesterID: semester.id, date: target, followsDate: semester.firstMonday)
        data.dayOverrides = [change]
        #expect(DraftValidator.issues(for: change, snapshot: data).isEmpty)
        try BackupCodec.validate(data)
        #expect(ScheduleEngine.occurrences(snapshot: data, semesterID: semester.id).contains { semester.calendar.isDate($0.start, inSameDayAs: target) })
    }

    @Test func requiresAllSourcePeriodsInTargetsEffectiveVersion() {
        var data = fixture(); let semester = data.semesters[0]
        let target = ScheduleEngine.date(week: 3, weekday: 6, semester: semester)
        data.bellSchedules.append(BellSchedule(semesterID: semester.id, name: "冬季", effectiveFrom: ScheduleEngine.date(week: 2, weekday: 1, semester: semester), periods: [Period(number: 1, startMinute: 510, endMinute: 555)], isConfirmed: true))
        let change = DayOverride(semesterID: semester.id, date: target, followsDate: semester.firstMonday)
        let issues = DraftValidator.issues(for: change, snapshot: data)
        #expect(issues.contains { $0.contains("第 2 节") })
        data.dayOverrides = [change]
        #expect(throws: (any Error).self) { try BackupCodec.validate(data) }
    }

    @Test func directTimesNeedNoBellAndTrulyEmptySourceCanClearDay() throws {
        var data = fixture(); let semester = data.semesters[0]
        data.bellSchedules = []
        data.rules[0].periodNumbers = []; data.rules[0].startMinute = 480; data.rules[0].endMinute = 525
        let target = semester.calendar.date(byAdding: .day, value: -2, to: semester.firstMonday)!
        let direct = DayOverride(semesterID: semester.id, date: target, followsDate: semester.firstMonday)
        data.dayOverrides = [direct]
        #expect(DraftValidator.issues(for: direct, snapshot: data).isEmpty)
        try BackupCodec.validate(data)
        let empty = DayOverride(semesterID: semester.id, date: semester.firstMonday, followsDate: ScheduleEngine.date(week: 1, weekday: 7, semester: semester))
        data.dayOverrides = [empty]
        #expect(DraftValidator.issues(for: empty, snapshot: data).isEmpty)
        try BackupCodec.validate(data)
        #expect(ScheduleEngine.occurrences(snapshot: data, semesterID: semester.id).isEmpty)
    }
}
